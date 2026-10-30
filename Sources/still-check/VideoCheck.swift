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

    static let probe = """
    const r = window.ytInitialPlayerResponse || {};
    return JSON.stringify({
        ads: !!(r.adPlacements || r.playerAds || r.adSlots),
        enforcement: JSON.stringify(r).includes('enforcementMessageViewModel'),
        video: !!(r.videoDetails && r.videoDetails.videoId),
        title: document.title
    });
    """

    private struct Probe: Decodable { let ads: Bool; let enforcement: Bool; let video: Bool; let title: String }

    func run() async -> [CheckResult] {
        var results: [CheckResult] = []
        let cookies = Self.consentCookie.map { [$0] } ?? []
        for id in Self.videos {
            guard let url = URL(string: "https://www.youtube.com/watch?v=\(id)") else { continue }
            let without = await probe(url, scripts: [], cookies: cookies)
            let with = await probe(url, scripts: [script], cookies: cookies)
            guard let without, let with else {
                results.append(CheckResult(name: "YouTube \(id)", passed: false, meaningful: false, details: ["Seite nicht auswertbar"]))
                continue
            }
            let meaningful = without.ads && without.video
            results.append(CheckResult(
                name: "YouTube \(id)",
                passed: with.video && !with.ads && !with.enforcement,
                meaningful: meaningful,
                details: [
                    "ohne Skript: Werbedaten \(without.ads ? "ja" : "nein"), Video \(without.video ? "ja" : "nein")",
                    "mit Skript: Werbedaten \(with.ads ? "JA" : "nein"), Anti-Adblock \(with.enforcement ? "JA" : "nein"), Video \(with.video ? "ja" : "FEHLT")",
                    "Titel: \(with.title.prefix(60))",
                ]))
        }
        return results
    }

    private func probe(_ url: URL, scripts: [String], cookies: [HTTPCookie]) async -> Probe? {
        guard let json = await runner.load(url: url, lists: [], settle: .seconds(4), script: Self.probe,
                                           pageScripts: scripts, cookies: cookies) as? String else { return nil }
        return try? JSONDecoder().decode(Probe.self, from: Data(json.utf8))
    }
}
