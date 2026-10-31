import Foundation
import WebKit

/// Ergebnis einer Prüfung, wie es im Bericht erscheint.
struct CheckResult: Codable {
    var name: String
    var passed: Bool
    /// false = Prüfung nicht aussagekräftig (z. B. Seite lädt ohne Zustimmung gar keine Werbung)
    var meaningful = true
    var details: [String] = []
}

/// Bekannte Werbe- und Tracker-Ressourcen plus unverdächtige Gegenproben.
enum TestPage {
    static let base = URL(string: "https://www.example.org/still-check")!

    static let blockable: [(url: String, kind: String)] = [
        ("https://securepubads.g.doubleclick.net/tag/js/gpt.js", "script"),
        ("https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js", "script"),
        ("https://www.google-analytics.com/analytics.js", "script"),
        ("https://www.googletagmanager.com/gtag/js?id=G-STILLTEST", "script"),
        ("https://connect.facebook.net/en_US/fbevents.js", "script"),
        ("https://static.criteo.net/js/ld/publishertag.js", "script"),
        ("https://cdn.taboola.com/libtrc/unip/1/tfa.js", "script"),
        ("https://widgets.outbrain.com/outbrain.js", "script"),
        ("https://c.amazon-adsystem.com/aax2/apstag.js", "script"),
        ("https://bat.bing.com/bat.js", "script"),
        ("https://static.hotjar.com/c/hotjar-1.js?sv=6", "script"),
        ("https://sb.scorecardresearch.com/beacon.js", "script"),
        ("https://www.facebook.com/tr?id=1&ev=PageView&noscript=1", "img"),
    ]

    /// Dürfen nie geblockt werden (Fehlalarm-Kontrolle)
    static let controls: [(url: String, kind: String)] = [
        ("https://code.jquery.com/jquery-3.7.1.min.js", "script"),
        ("https://cdnjs.cloudflare.com/ajax/libs/lodash.js/4.17.21/lodash.min.js", "script"),
        ("https://cdn.jsdelivr.net/npm/vue@3.4.21/dist/vue.global.prod.js", "script"),
        ("https://www.apple.com/favicon.ico", "img"),
    ]

    /// Ausblende-Selektoren, die in EasyList bzw. den Cookie-Listen stehen
    static let hiddenSelectors = ["#sidebar-ads", ".ad-slot", ".google-ads", ".ad_wrapper", "#cookie-banner"]
    /// Dürfen nie ausgeblendet sein: die Seite selbst und ihr Hauptinhalt
    static let visibleSelectors = ["html", "body", "#content", ".article"]

    static var html: String {
        let hidden = hiddenSelectors.map { selector -> String in
            selector.hasPrefix("#") ? "<div id=\"\(selector.dropFirst())\">Anzeige</div>" : "<div class=\"\(selector.dropFirst())\">Anzeige</div>"
        }.joined()
        return "<!doctype html><html><head><title>Still Check</title></head><body><main id=\"content\"><article class=\"article\">Normaler Inhalt</article></main>\(hidden)</body></html>"
    }

    static func script(_ resources: [(url: String, kind: String)]) -> String {
        let list = resources.map { "[\"\($0.url)\", \"\($0.kind)\"]" }.joined(separator: ",")
        let selectors = (hiddenSelectors + visibleSelectors).map { "\"\($0)\"" }.joined(separator: ",")
        return """
        const load = (url, kind) => new Promise(resolve => {
            const el = kind === 'img' ? new Image() : document.createElement('script');
            const timer = setTimeout(() => resolve('timeout'), 10000);
            el.onload = () => { clearTimeout(timer); resolve('loaded'); };
            el.onerror = () => { clearTimeout(timer); resolve('failed'); };
            el.src = url;
            if (kind !== 'img') document.head.appendChild(el);
        });
        const loads = {};
        await Promise.all([\(list)].map(async ([url, kind]) => { loads[url] = await load(url, kind); }));
        // Tatsächlich gerendert? Erfasst auch ausgeblendete Eltern, visibility und Opazität – nicht nur display
        const isHidden = el => typeof el.checkVisibility === 'function'
            ? !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
            : el.getClientRects().length === 0;
        const hidden = {};
        for (const sel of [\(selectors)]) {
            const el = document.querySelector(sel);
            hidden[sel] = el ? isHidden(el) : null;
        }
        return JSON.stringify({ loads, hidden });
        """
    }
}

/// Echte Seiten: Mit Blocker dürfen kaum noch Anfragen an Werbe-/Tracker-Server rausgehen,
/// und die Seite muss weiter funktionieren.
enum RealSites {
    static let urls = [
        "https://www.spiegel.de/",
        "https://www.t-online.de/",
        "https://www.chip.de/",
        "https://www.theguardian.com/international",
        "https://edition.cnn.com/",
        "https://www.foxnews.com/",
        "https://www.dailymail.co.uk/home/index.html",
        "https://www.wetter.com/",
        "https://www.giga.de/",
    ]

    /// So viele Seiten müssen ohne Blocker Werbung laden, damit die Prüfung echter Seiten etwas aussagt.
    /// Viele EU-Seiten laden vor der Cookie-Zustimmung gar keine Werbung.
    static let minimumMeaningful = 2

    static let adHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com", "adnxs.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "amazon-adsystem.com", "facebook.net",
        "scorecardresearch.com", "adsrvr.org", "pubmatic.com", "rubiconproject.com", "casalemedia.com", "openx.net",
        "smartadserver.com", "adform.net", "teads.tv", "moatads.com", "quantserve.com", "hotjar.com", "ioam.de",
        "chartbeat.com", "yieldlove.com", "permutive.com", "bing.com/action", "bat.bing.com", "pinimg.com/ct",
    ]

    /// innerText allein reicht nicht: Ist body ausgeblendet, liefert innerText trotzdem den ganzen Text.
    /// Deshalb zählt nur Text in Elementen, die wirklich gerendert sind und eine Fläche im Fenster haben.
    static let script = """
    const resources = performance.getEntriesByType('resource').map(e => e.name);
    const visible = el => (typeof el.checkVisibility === 'function'
            ? el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
            : el.getClientRects().length > 0)
        && el.getBoundingClientRect().width > 0 && el.getBoundingClientRect().height > 0;
    const body = document.body;
    const bodyVisible = !!body && visible(document.documentElement) && visible(body);
    let visibleTextLength = 0;
    if (bodyVisible) {
        const blocks = document.querySelectorAll('p, h1, h2, h3, h4, li, a, span, td, article, section');
        for (let i = 0; i < blocks.length && i < 4000 && visibleTextLength < 5000; i++) {
            const el = blocks[i];
            // Nur „Blätter“ zählen, sonst wird verschachtelter Text mehrfach gezählt
            if (el.querySelector('p, h1, h2, h3, h4, li, a, span, td, article, section')) continue;
            if (visible(el)) visibleTextLength += (el.innerText || '').trim().length;
        }
    }
    return JSON.stringify({
        title: document.title,
        textLength: body ? body.innerText.length : 0,
        bodyVisible,
        visibleTextLength,
        resources
    });
    """

    static func adRequests(_ resources: [String]) -> [String] {
        resources.filter { url in adHosts.contains { url.contains($0) } }
    }
}

@MainActor
struct Verifier {
    let runner: WebKitRunner
    let lists: [WKContentRuleList]

    func testPage() async -> [CheckResult] {
        let all = TestPage.blockable + TestPage.controls
        let script = TestPage.script(all)
        guard let baseJSON = await runner.load(html: TestPage.html, url: TestPage.base, lists: [], settle: .seconds(1), script: script) as? String,
              let blockedJSON = await runner.load(html: TestPage.html, url: TestPage.base, lists: lists, settle: .seconds(1), script: script) as? String,
              let base = decode(baseJSON), let blocked = decode(blockedJSON)
        else {
            return [CheckResult(name: "Testseite", passed: false, details: ["Testseite ließ sich nicht auswerten"])]
        }

        // Nur zählen, was ohne Blocker erreichbar war: so führen Netzprobleme nicht zu falschem Erfolg
        var reachable = 0, stopped = 0, missed: [String] = []
        for item in TestPage.blockable where base.loads[item.url] == "loaded" {
            reachable += 1
            if blocked.loads[item.url] == "loaded" { missed.append(item.url) } else { stopped += 1 }
        }
        let falsePositives = TestPage.controls.filter { base.loads[$0.url] == "loaded" && blocked.loads[$0.url] != "loaded" }.map(\.url)

        var results: [CheckResult] = []
        let rate = reachable == 0 ? 0 : Double(stopped) / Double(reachable)
        results.append(CheckResult(
            name: "Werbe- und Tracker-Skripte geblockt",
            passed: reachable > 0 && rate >= 0.9,
            meaningful: reachable > 0,
            details: ["\(stopped) von \(reachable) erreichbaren Ressourcen geblockt (\(Int(rate * 100)) %)"] + missed.map { "nicht geblockt: \($0)" }
        ))
        results.append(CheckResult(
            name: "Keine Fehlalarme bei normalen Bibliotheken",
            passed: falsePositives.isEmpty,
            details: falsePositives.isEmpty ? ["\(TestPage.controls.count) Gegenproben geladen"] : falsePositives.map { "fälschlich geblockt: \($0)" }
        ))
        let hiddenCount = TestPage.hiddenSelectors.filter { blocked.hidden[$0] == true }.count
        let wronglyHidden = TestPage.visibleSelectors.filter { blocked.hidden[$0] == true }
        results.append(CheckResult(
            name: "Werbeflächen ausgeblendet",
            passed: hiddenCount >= 3 && wronglyHidden.isEmpty,
            details: ["\(hiddenCount) von \(TestPage.hiddenSelectors.count) Testflächen ausgeblendet: "
                      + TestPage.hiddenSelectors.map { "\($0)=\(blocked.hidden[$0] == true ? "weg" : "sichtbar")" }.joined(separator: ", ")]
                + wronglyHidden.map { "fälschlich ausgeblendet: \($0)" }
        ))
        return results
    }

    func realSites() async -> [CheckResult] {
        var results: [CheckResult] = []
        for site in RealSites.urls {
            guard let url = URL(string: site) else { continue }
            let without = await snapshot(url, lists: [])
            let with = await snapshot(url, lists: lists)
            guard let without, let with else {
                results.append(CheckResult(name: site, passed: false, meaningful: false, details: ["Seite nicht ladbar"]))
                continue
            }
            let before = RealSites.adRequests(without.resources)
            let after = RealSites.adRequests(with.resources)
            let healthy = with.bodyVisible && with.visibleTextLength > 300 && !with.title.isEmpty
            let meaningful = !before.isEmpty
            let reduced = before.isEmpty || after.count <= max(1, before.count / 10)
            var details = ["Werbe-/Tracker-Anfragen ohne Blocker: \(before.count), mit Blocker: \(after.count)",
                           "Seite intakt: \(healthy ? "ja" : "NEIN") (Titel „\(with.title.prefix(60))“, body \(with.bodyVisible ? "sichtbar" : "AUSGEBLENDET"), "
                           + "\(with.visibleTextLength) Zeichen sichtbarer Text, \(with.textLength) Zeichen insgesamt)"]
            details += Set(after.compactMap { URL(string: $0)?.host }).sorted().prefix(5).map { "noch durchgekommen: \($0)" }
            results.append(CheckResult(name: site, passed: healthy && reduced, meaningful: meaningful, details: details))
        }
        let meaningful = results.filter(\.meaningful).count
        results.append(CheckResult(
            name: "Genug aussagekräftige echte Seiten",
            passed: meaningful >= RealSites.minimumMeaningful,
            details: ["\(meaningful) von \(RealSites.urls.count) Seiten laden ohne Blocker Werbung (mindestens \(RealSites.minimumMeaningful) nötig)"]
        ))
        return results
    }

    private struct PageSnapshot: Decodable {
        let title: String; let textLength: Int; let bodyVisible: Bool; let visibleTextLength: Int; let resources: [String]
    }

    /// Hauptseiten wichtiger Dienste dürfen nie als Ganzes geblockt werden (wäre für Nutzer eine leere Seite).
    /// WebKit meldet einen vom Content-Blocker gestoppten Seitenabruf als Fehler 104 der WebKitErrorDomain;
    /// Netzfehler zählen nicht als geblockt.
    func mainFrames(_ hosts: [String]) async -> [CheckResult] {
        var blocked: [String] = [], unclear: [String] = []
        for host in hosts {
            guard let url = URL(string: "https://\(host)/") else { unclear.append(host); continue }
            switch await runner.probeMainFrame(url, lists: lists) {
            case .blocked: blocked.append(host)
            case .allowed: break
            case .unknown: unclear.append(host)
            }
        }
        var details = ["\(hosts.count - blocked.count - unclear.count) von \(hosts.count) Hauptseiten geladen bzw. nicht vom Blocker gestoppt"]
        details += blocked.map { "Hauptseite geblockt: \($0)" }
        details += unclear.map { "ohne Ergebnis (Zeitüberschreitung): \($0)" }
        return [CheckResult(name: "Wichtige Dienste als Hauptseite nicht geblockt", passed: blocked.isEmpty, details: details)]
    }

    private func snapshot(_ url: URL, lists: [WKContentRuleList]) async -> PageSnapshot? {
        guard let json = await runner.load(url: url, lists: lists, settle: .seconds(6), script: RealSites.script) as? String else { return nil }
        return try? JSONDecoder().decode(PageSnapshot.self, from: Data(json.utf8))
    }

    private struct PageResult: Decodable { let loads: [String: String]; let hidden: [String: Bool?] }

    private func decode(_ json: String) -> (loads: [String: String], hidden: [String: Bool])? {
        guard let result = try? JSONDecoder().decode(PageResult.self, from: Data(json.utf8)) else { return nil }
        return (result.loads, result.hidden.compactMapValues { $0 })
    }
}
