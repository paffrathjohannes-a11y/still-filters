import Foundation

/// Prüft das YouTube-Skript der Video-Erweiterung mit echtem WebKit: Ein Video wird ohne und mit Skript
/// geladen. Mit Skript dürfen keine Werbedaten mehr beim Player ankommen, und das Video muss intakt bleiben.
@MainActor
struct VideoCheck {
    let runner: WebKitRunner
    let script: String

    /// Bekannte, dauerhaft verfügbare Videos (Musik, Trailer: werden in der Regel mit Werbung ausgeliefert)
    static let videos = ["dQw4w9WgXcQ", "kJQP7kiw5Fk", "9bZkp7q19f0"]

    /// „Alle ablehnen“ der YouTube-Einwilligung, damit EU-Abrufe direkt auf der Videoseite landen
    static var consentCookie: HTTPCookie? {
        HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: "SOCS", .value: "CAI", .secure: "TRUE",
                                .expires: Date().addingTimeInterval(3600)])
    }

    /// Sucht Werbe-Felder in den Daten, die der Player tatsächlich verwendet (bei der iPhone-Version werden sie
    /// nachträglich geladen), ersatzweise in den eingebetteten Startdaten. Gesucht wird nach Feldnamen, nicht nach
    /// Text: Ein Wort wie „adSlotRenderer“ kann auch harmlos in Textwerten vorkommen.
    static let probe = """
    const el = document.getElementById('movie_player') || document.querySelector('.html5-video-player');
    let live = null;
    try { live = el && el.getPlayerResponse ? el.getPlayerResponse() : null; } catch (e) {}
    const r = (live && live.videoDetails) ? live : (window.ytInitialPlayerResponse || {});
    let ads = false, enforcement = false;
    const walk = (o, d) => {
        if (!o || typeof o !== 'object' || d > 25) return;
        for (const k of Object.keys(o)) {
            if (/^(adPlacements|playerAds|adSlots|adBreakHeartbeatParams)$/.test(k)) ads = true;
            if (k === 'enforcementMessageViewModel') enforcement = true;
            walk(o[k], d + 1);
        }
    };
    walk(r, 0);
    return JSON.stringify({ ads, enforcement, video: !!(r.videoDetails && r.videoDetails.videoId),
                            title: document.title + (live ? ' [Player]' : ' [eingebettet]') });
    """

    private struct Probe: Decodable { let ads: Bool; let enforcement: Bool; let video: Bool; let title: String }

    static let iPhoneAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    func run() async -> [CheckResult] {
        var results: [CheckResult] = []
        let cookies = Self.consentCookie.map { [$0] } ?? []
        // Desktop und iPhone: m.youtube.com liefert andere Seiten und Daten aus
        let variants: [(label: String, host: String, agent: String?)] = [("", "www.youtube.com", nil),
                                                                        (" (iPhone)", "m.youtube.com", Self.iPhoneAgent)]
        for variant in variants {
        for id in Self.videos {
            guard let url = URL(string: "https://\(variant.host)/watch?v=\(id)") else { continue }
            let without = await probe(url, scripts: [], cookies: cookies, agent: variant.agent)
            let with = await probe(url, scripts: [script], cookies: cookies, agent: variant.agent)
            guard let without, let with else {
                results.append(CheckResult(name: "YouTube \(id)\(variant.label)", passed: false, meaningful: false, details: ["Seite nicht auswertbar"]))
                continue
            }
            let meaningful = without.ads && without.video
            results.append(CheckResult(
                name: "YouTube \(id)\(variant.label)",
                passed: with.video && !with.ads && !with.enforcement,
                meaningful: meaningful,
                details: [
                    "ohne Skript: Werbedaten \(without.ads ? "ja" : "nein"), Video \(without.video ? "ja" : "nein")",
                    "mit Skript: Werbedaten \(with.ads ? "JA" : "nein"), Anti-Adblock \(with.enforcement ? "JA" : "nein"), Video \(with.video ? "ja" : "FEHLT")",
                    "Titel: \(with.title.prefix(60))",
                ]))
        }
        }
        return results
    }

    private func probe(_ url: URL, scripts: [String], cookies: [HTTPCookie], agent: String?) async -> Probe? {
        guard let json = await runner.load(url: url, lists: [], settle: .seconds(5), script: Self.probe,
                                           pageScripts: scripts, cookies: cookies, userAgent: agent) as? String else { return nil }
        return try? JSONDecoder().decode(Probe.self, from: Data(json.utf8))
    }
}
