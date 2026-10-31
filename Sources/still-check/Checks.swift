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
    /// Dürfen nie ausgeblendet sein: die Seite selbst, ihr Gerüst und typische Inhaltselemente. Die Seite ist wie
    /// echte Seiten aufgebaut (lang/dir/class an <html>, div/header/nav/section/p/span/a/img), damit zu allgemeine
    /// Selektoren wie `div`, `[lang]` oder `:not(.x)` hier auffallen.
    static let visibleSelectors = ["html", "body", "#page", "header", "nav", "#content", "section", ".article",
                                   "p", "span", "a", "img", "footer"]

    /// 1×1-GIF, damit <img> ohne Netz sicher geladen und sichtbar ist
    private static let pixel = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    static var html: String {
        let hidden = hiddenSelectors.map { selector -> String in
            selector.hasPrefix("#") ? "<div id=\"\(selector.dropFirst())\">Anzeige</div>" : "<div class=\"\(selector.dropFirst())\">Anzeige</div>"
        }.joined()
        return """
        <!doctype html><html lang="de" dir="ltr" class="js no-touch"><head><meta charset="utf-8"><title>Still Check</title></head>\
        <body class="home"><div id="page"><header><nav><a href="/start">Start</a></nav></header>\
        <main id="content"><section><article class="article"><p>Normaler <span>Inhalt</span> mit \
        <a href="/mehr">Link</a> <img src="\(pixel)" width="20" height="20" alt="Bild"></p></article></section></main>\
        \(hidden)<footer><p>Impressum</p></footer></div></body></html>
        """
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

    /// Schaden durch den Blocker im Vergleich zum Lauf ohne ihn, nil = intakt
    static func damage(without: Verifier.PageSnapshot, with: Verifier.PageSnapshot) -> String? {
        guard without.bodyVisible else { return nil }
        if !with.bodyVisible { return "Seite (html/body) mit Blocker ausgeblendet" }
        if without.visibleTextLength >= 400, with.visibleTextLength * 4 < without.visibleTextLength {
            return "sichtbarer Text eingebrochen: \(with.visibleTextLength) statt \(without.visibleTextLength) Zeichen"
        }
        return nil
    }

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
        func run() async -> (base: PageData, blocked: PageData)? {
            guard let baseJSON = await runner.load(html: TestPage.html, url: TestPage.base, lists: [], settle: .seconds(1), script: script) as? String,
                  let blockedJSON = await runner.load(html: TestPage.html, url: TestPage.base, lists: lists, settle: .seconds(1), script: script) as? String,
                  let base = decode(baseJSON), let blocked = decode(blockedJSON)
            else { return nil }
            return (base, blocked)
        }
        /// Vom Blocker gestoppte Gegenproben. Nur „failed“ zählt: Safari meldet geblockte Ressourcen sofort als Fehler,
        /// eine Zeitüberschreitung ist ein Netzproblem und kein Fehlalarm.
        func falsePositives(_ pair: (base: PageData, blocked: PageData)) -> [String] {
            TestPage.controls.filter { pair.base.loads[$0.url] == "loaded" && pair.blocked.loads[$0.url] == "failed" }.map(\.url)
        }

        // Ein Netzaussetzer darf den täglichen Bau nicht scheitern lassen: einmal wiederholen, und ein Fehlalarm
        // zählt nur, wenn er in beiden Durchgängen auftritt.
        var first = await run()
        if first == nil { first = await run() }
        guard var pair = first else {
            return [CheckResult(name: "Testseite", passed: false, details: ["Testseite ließ sich (auch im zweiten Versuch) nicht auswerten"])]
        }
        var wrongControls = falsePositives(pair)
        if !wrongControls.isEmpty, let second = await run() {
            wrongControls = wrongControls.filter(falsePositives(second).contains)
            if wrongControls.isEmpty { pair = second }
        }
        let (base, blocked) = pair

        // Nur zählen, was ohne Blocker erreichbar war: so führen Netzprobleme nicht zu falschem Erfolg
        var reachable = 0, stopped = 0, missed: [String] = []
        for item in TestPage.blockable where base.loads[item.url] == "loaded" {
            reachable += 1
            if blocked.loads[item.url] == "loaded" { missed.append(item.url) } else { stopped += 1 }
        }

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
            passed: wrongControls.isEmpty,
            details: wrongControls.isEmpty ? ["\(TestPage.controls.count) Gegenproben nicht geblockt"] : wrongControls.map { "fälschlich geblockt: \($0)" }
        ))
        let hiddenCount = TestPage.hiddenSelectors.filter { blocked.hidden[$0] == true }.count
        // Ohne Blocker müssen alle Kontroll-Elemente sichtbar sein, sonst ist die Testseite selbst kaputt
        let brokenPage = TestPage.visibleSelectors.filter { base.hidden[$0] != false }
        let wronglyHidden = TestPage.visibleSelectors.filter { blocked.hidden[$0] != false }
        results.append(CheckResult(
            name: "Werbeflächen ausgeblendet, Seite und Inhalt sichtbar",
            passed: hiddenCount >= 3 && wronglyHidden.isEmpty && brokenPage.isEmpty,
            details: ["\(hiddenCount) von \(TestPage.hiddenSelectors.count) Testflächen ausgeblendet: "
                      + TestPage.hiddenSelectors.map { "\($0)=\(blocked.hidden[$0] == true ? "weg" : "sichtbar")" }.joined(separator: ", "),
                      "\(TestPage.visibleSelectors.count - wronglyHidden.count) von \(TestPage.visibleSelectors.count) Inhaltselementen sichtbar"]
                + wronglyHidden.map { "fälschlich ausgeblendet: \($0)" }
                + brokenPage.map { "Testseite fehlerhaft, schon ohne Blocker unsichtbar: \($0)" }
        ))
        return results
    }

    /// Pro Seite ein weiches Ergebnis (Werbung reduziert?) und über alle Seiten ein hartes: „Echte Seiten intakt“.
    /// Hart heißt: Seite mit Blocker ausgeblendet (html/body) oder sichtbarer Text auf unter ein Viertel eingebrochen,
    /// jeweils im Vergleich zum Lauf ohne Blocker und in einem zweiten Durchgang bestätigt.
    func realSites(_ urls: [String] = RealSites.urls) async -> [CheckResult] {
        var results: [CheckResult] = []
        var checked = 0
        var broken: [String] = []
        for site in urls {
            guard let url = URL(string: site) else { continue }
            guard var without = await snapshot(url, lists: []), var with = await snapshot(url, lists: lists) else {
                results.append(CheckResult(name: site, passed: false, meaningful: false, details: ["Seite nicht ladbar"]))
                continue
            }
            var damage = RealSites.damage(without: without, with: with)
            if damage != nil, let againWithout = await snapshot(url, lists: []), let againWith = await snapshot(url, lists: lists) {
                // Nur bestätigte Schäden zählen (Seiten ändern sich zwischen zwei Aufrufen)
                if RealSites.damage(without: againWithout, with: againWith) == nil {
                    damage = nil
                    (without, with) = (againWithout, againWith)
                }
            }
            if without.bodyVisible { checked += 1 }
            if let damage { broken.append("\(site): \(damage)") }

            let before = RealSites.adRequests(without.resources)
            let after = RealSites.adRequests(with.resources)
            let healthy = damage == nil && with.bodyVisible && !with.title.isEmpty
            let meaningful = !before.isEmpty
            let reduced = before.isEmpty || after.count <= max(1, before.count / 10)
            var details = ["Werbe-/Tracker-Anfragen ohne Blocker: \(before.count), mit Blocker: \(after.count)",
                           "Seite intakt: \(healthy ? "ja" : "NEIN") (Titel „\(with.title.prefix(60))“, body \(with.bodyVisible ? "sichtbar" : "AUSGEBLENDET"), "
                           + "sichtbarer Text \(with.visibleTextLength) Zeichen mit, \(without.visibleTextLength) ohne Blocker)"]
            details += Set(after.compactMap { URL(string: $0)?.host }).sorted().prefix(5).map { "noch durchgekommen: \($0)" }
            results.append(CheckResult(name: site, passed: healthy && reduced, meaningful: meaningful, details: details))
        }
        results.append(CheckResult(
            name: "Echte Seiten intakt",
            passed: broken.isEmpty,
            meaningful: checked > 0,
            details: ["\(checked - broken.count) von \(checked) ladbaren Seiten mit Blocker intakt"] + broken
        ))
        let meaningful = results.filter { $0.meaningful && $0.name.hasPrefix("http") }.count
        if urls == RealSites.urls {
            results.append(CheckResult(
                name: "Genug aussagekräftige echte Seiten",
                passed: meaningful >= RealSites.minimumMeaningful,
                details: ["\(meaningful) von \(urls.count) Seiten laden ohne Blocker Werbung (mindestens \(RealSites.minimumMeaningful) nötig)"]
            ))
        }
        return results
    }

    struct PageSnapshot: Decodable {
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

    typealias PageData = (loads: [String: String], hidden: [String: Bool])

    private func decode(_ json: String) -> PageData? {
        guard let result = try? JSONDecoder().decode(PageResult.self, from: Data(json.utf8)) else { return nil }
        return (result.loads, result.hidden.compactMapValues { $0 })
    }
}
