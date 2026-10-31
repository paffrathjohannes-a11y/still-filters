import XCTest
@testable import StillFilterKit

final class ParserTests: XCTestCase {
    func testDomainBlockWithOptions() throws {
        guard case .network(let rule) = RuleParser.parse("||ads.example.com^$third-party,script,domain=a.de|b.com") else {
            return XCTFail("keine Netzwerkregel")
        }
        XCTAssertEqual(rule.pattern, "||ads.example.com^")
        XCTAssertEqual(rule.thirdParty, true)
        XCTAssertEqual(rule.resourceTypes, [.script])
        XCTAssertEqual(rule.includeDomains, ["a.de", "b.com"])
    }

    func testNegatedTypesBecomeComplement() throws {
        guard case .network(let rule) = RuleParser.parse("||cdn.example^$~image") else { return XCTFail() }
        XCTAssertFalse(rule.resourceTypes.contains(.image))
        XCTAssertTrue(rule.resourceTypes.contains(.script))
        XCTAssertFalse(rule.resourceTypes.contains(.popup))
    }

    func testExceptionScopes() {
        guard case .network(let doc) = RuleParser.parse("@@||bank.de^$document") else { return XCTFail() }
        XCTAssertEqual(doc.exceptionScope, .document)
        guard case .network(let hide) = RuleParser.parse("@@||news.de^$elemhide") else { return XCTFail() }
        XCTAssertEqual(hide.exceptionScope, .elementHiding)
    }

    func testCosmetic() {
        XCTAssertEqual(RuleParser.parse("##.ad-banner"), .cosmetic(CosmeticRule(selector: ".ad-banner")))
        XCTAssertEqual(RuleParser.parse("###sidebar-ad"), .cosmetic(CosmeticRule(selector: "#sidebar-ad")))
        XCTAssertEqual(RuleParser.parse("spiegel.de,~m.spiegel.de##.teaser-ad"),
                       .cosmetic(CosmeticRule(includeDomains: ["spiegel.de"], excludeDomains: ["m.spiegel.de"], selector: ".teaser-ad")))
        XCTAssertEqual(RuleParser.parse("example.com#@#.ad"),
                       .cosmetic(CosmeticRule(isException: true, includeDomains: ["example.com"], selector: ".ad")))
    }

    func testGenericPageSelectorsAreRejected() {
        for selector in ["html", "body", ":root", "*", "main", "#content", "body > div.ad", "html.no-js .x",
                         "*[id^=ad]", "main .ad", "#content > .promo", ".ad-box, body", "BODY", "body:not(.x)"] {
            XCTAssertEqual(RuleParser.parse("##" + selector), .unsupported("page-selector"), selector)
            XCTAssertEqual(RuleParser.parse("~example.com##" + selector), .unsupported("page-selector"), selector)
        }
        // Nur als ganzes Token: ähnliche Namen sind normale Werbeflächen
        for selector in ["#content-ad", ".main-ad", "mainbar", "#contentAd", ".body-banner", "htmlads", "div[class=\"body\"]",
                         ".a:is(main, body)"] {
            XCTAssertEqual(RuleParser.parse("##" + selector), .cosmetic(CosmeticRule(selector: selector)), selector)
        }
        // Für einzelne Seiten und als Ausnahme bleibt es erlaubt
        XCTAssertEqual(RuleParser.parse("example.com##body > .overlay"),
                       .cosmetic(CosmeticRule(includeDomains: ["example.com"], selector: "body > .overlay")))
        XCTAssertEqual(RuleParser.parse("#@#body"), .cosmetic(CosmeticRule(isException: true, selector: "body")))
    }

    /// Die App lehnt eine ganze Liste ab, sobald eine Regel – auch nur für einzelne Domains – html/body/:root/* ausblendet
    /// (EasyList: `aads.com,…##HTML`, EasyList China: `pos.baidu.com##body`). Solche Regeln dürfen nie durchgehen.
    func testDomainScopedWholePageSelectorsAreRejected() {
        for line in ["aads.com,yavli.com##HTML", "pos.baidu.com##body", "example.ru##*", "example.fr##html", "a.de##:root",
                     "a.de##.ad, body", "a.de##body > *", "a.de##HTML  BODY"] {
            XCTAssertEqual(RuleParser.parse(Substring(line)), .unsupported("page-selector"), line)
        }
    }

    func testTooGenericSelectorsAreRejected() {
        for selector in [":not(.x)", ":is(html)", ":where(body)", "[lang]", "[dir]", "[class]", "[id]", "[style]", "div",
                         "section", "p", "span", "a > img", "div > *", "div:nth-child(2)", ":has(img)", "section p", "img[alt]",
                         ".ad, div", ":is(.a, div)"] {
            XCTAssertEqual(RuleParser.parse(Substring("##" + selector)), .unsupported("generic-selector"), selector)
        }
        // Mit unterscheidendem Merkmal bleiben sie erhalten (alles echte Regeln aus EasyList und den Sprachlisten)
        for selector in ["[data-ad-cls]", "[data-freestar-ad][id]", "amp-ad", "adsenseintermedioleft", "div[data-ad]",
                         "a[href^=\"https://halocell.com/go/\"] > img", "#\\5f CookieText", ".ad:not(.x)", ":is(.a, .b)",
                         "img[width=\"728\"]", "#asdw2 + img", "div[class] > .ad"] {
            XCTAssertEqual(RuleParser.parse(Substring("##" + selector)), .cosmetic(CosmeticRule(selector: selector)), selector)
        }
        // Für einzelne Seiten erlaubt
        XCTAssertEqual(RuleParser.parse("example.com##div > p"),
                       .cosmetic(CosmeticRule(includeDomains: ["example.com"], selector: "div > p")))
    }

    func testAppListCheckMirrorsApp() throws {
        func problems(_ json: String, _ expect: Int? = nil) -> [AppListCheck.Problem] {
            AppListCheck.problems(Data(json.utf8), expectedRules: expect)
        }
        let scopedHTML = #"[{"trigger":{"url-filter":".*","if-domain":["*aads.com"]},"action":{"type":"css-display-none","selector":"HTML"}}]"#
        XCTAssertFalse(problems(scopedHTML).isEmpty, "die App lehnt auch domain-beschränkte Seiten-Selektoren ab")
        let blockAll = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        XCTAssertFalse(problems(blockAll).isEmpty)
        let scopedBlock = #"[{"trigger":{"url-filter":".*","if-domain":["*x.de"]},"action":{"type":"block"}}]"#
        XCTAssertTrue(problems(scopedBlock).isEmpty)
        let fine = #"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".ad, #banner"}}]"#
        XCTAssertTrue(problems(fine, 1).isEmpty)
        XCTAssertFalse(problems(fine, 2).isEmpty, "Regelzahl muss zum Manifest passen")
        XCTAssertFalse(problems("{}").isEmpty)
    }

    /// Was der Konverter ausgibt, muss die App immer annehmen – auch wenn die Quellen Seiten-Selektoren enthalten.
    func testConverterOutputPassesAppCheck() throws {
        let result = SafariConverter.convert(lines: """
        ##.ad
        aads.com,yavli.com##HTML
        pos.baidu.com##body
        example.ru##*
        example.com##.teaser, body
        ##div
        ||ads.example^
        """.split(whereSeparator: \.isNewline))
        let data = try JSONEncoder().encode(result.rules)
        XCTAssertEqual(AppListCheck.problems(data, expectedRules: result.rules.count), [])
    }

    func testUnsupportedIsReportedNotDropped() {
        XCTAssertEqual(RuleParser.parse("youtube.com##+js(json-prune, playerResponse.adPlacements)"), .unsupported("scriptlet"))
        XCTAssertEqual(RuleParser.parse("example.com##div:has-text(Anzeige)"), .unsupported("procedural-selector"))
        XCTAssertEqual(RuleParser.parse("||example.com^$redirect=noopjs"), .unsupported("option-redirect=noopjs"))
        XCTAssertEqual(RuleParser.parse("example.com#?#div:-abp-has(.ad)"), .unsupported("extended-css"))
    }

    func testCommentsAndHosts() {
        XCTAssertEqual(RuleParser.parse("! Titel"), .comment)
        XCTAssertEqual(RuleParser.parse("[Adblock Plus 2.0]"), .comment)
        XCTAssertEqual(RuleParser.parse("# hosts comment"), .comment)
        XCTAssertEqual(RuleParser.parse("0.0.0.0 tracker.example"), .network(NetworkRule(pattern: "||tracker.example^")))
        XCTAssertEqual(RuleParser.parse("malware.example.net"), .network(NetworkRule(pattern: "||malware.example.net^")))
    }

    func testURLWithHashIsNetworkRule() {
        guard case .network = RuleParser.parse("||example.com/page#ad") else { return XCTFail("als Ausblende-Regel erkannt") }
    }
}

final class PatternTests: XCTestCase {
    private func regex(_ pattern: String) -> String? { URLPattern.convertPattern(pattern) }

    func testDomainAnchor() {
        XCTAssertEqual(regex("||ads.example.com^"), "^[^:]+://+([^:/]+\\.)?ads\\.example\\.com[/:]")
    }

    func testWildcardsAndSeparators() {
        XCTAssertEqual(regex("/banner/*/ad.js"), "/banner/.*/ad\\.js")
        XCTAssertEqual(regex("|https://"), "^https://")
        XCTAssertEqual(regex("&ad_type=^"), "&ad_type=[/:&?=]")
        XCTAssertEqual(regex("*"), ".*")
    }

    func testPatternMatchesLikeABP() throws {
        let filter = try XCTUnwrap(regex("||doubleclick.net^"))
        let re = try NSRegularExpression(pattern: filter, options: .caseInsensitive)
        func matches(_ url: String) -> Bool { re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        XCTAssertTrue(matches("https://doubleclick.net/x"))
        XCTAssertTrue(matches("https://stats.g.doubleclick.net/collect"))
        XCTAssertTrue(matches("https://ad.doubleclick.net:443/x"))
        XCTAssertFalse(matches("https://doubleclick.network/x"))
        XCTAssertFalse(matches("https://notdoubleclick.net/x"))
        XCTAssertFalse(matches("https://example.com/?u=doubleclick.net"))
    }

    func testRegexRules() {
        XCTAssertEqual(URLPattern.convertRegex("^https?:\\/\\/ads\\."), "^https?://ads\\.")
        XCTAssertNil(URLPattern.convertRegex("(ad|banner)\\.js"))
        XCTAssertNil(URLPattern.convertRegex("\\d{3}\\.js"))
    }
}

final class ConverterTests: XCTestCase {
    private func convert(_ text: String) -> ConversionResult {
        SafariConverter.convert(lines: text.split(whereSeparator: \.isNewline))
    }

    func testOrderingPutsExceptionsAfterBlocks() {
        let result = convert("""
        @@||cdn.example.com^$document
        @@||ads.example.com/ok.js
        ||ads.example.com^
        ##.ad
        @@||news.de^$generichide
        """)
        let types = result.rules.map(\.action.type)
        XCTAssertEqual(types, ["css-display-none", "ignore-previous-rules", "block", "ignore-previous-rules", "ignore-previous-rules"])
        XCTAssertEqual(result.rules.last?.trigger.ifDomain, ["*cdn.example.com"])
        XCTAssertEqual(result.rules[1].trigger.ifDomain, ["*news.de"])
    }

    func testCosmeticExceptionsAndBatching() {
        let result = convert("""
        ##.ad
        ##.banner
        example.com#@#.ad
        site.de##.promo
        other.de##.promo
        site.de#@#.promo
        """)
        let css = result.rules.filter { $0.action.type == "css-display-none" }
        XCTAssertTrue(css.contains { $0.action.selector == ".banner" && $0.trigger.unlessDomain == nil })
        XCTAssertTrue(css.contains { $0.action.selector == ".ad" && $0.trigger.unlessDomain == ["*example.com"] })
        XCTAssertTrue(css.contains { $0.action.selector == ".promo" && $0.trigger.ifDomain == ["*other.de"] })
    }

    func testBadfilterRemovesRule() {
        let result = convert("""
        ||good-cdn.com^$third-party
        ||good-cdn.com^$third-party,badfilter
        """)
        XCTAssertEqual(result.rules.count, 0)
        XCTAssertEqual(result.stats.badfilterRemoved, 1)
    }

    func testLimitDropsBlocksNotExceptions() {
        var lines = (0..<10).map { "||ad\($0).example^" }
        lines.append("@@||ad1.example^$document")
        let result = SafariConverter.convert(lines: lines.map { Substring($0) }, maxRules: 5)
        XCTAssertEqual(result.rules.count, 5)
        XCTAssertEqual(result.rules.last?.action.type, "ignore-previous-rules")
        XCTAssertEqual(result.stats.discardedOverLimit, 6)
    }

    func testJSONUsesWebKitKeys() throws {
        let json = try convert("||ads.example^$third-party,image").json()
        XCTAssertTrue(json.contains("\"url-filter\""))
        XCTAssertTrue(json.contains("\"load-type\":[\"third-party\"]"))
        XCTAssertTrue(json.contains("\"resource-type\":[\"image\"]"))
    }
}
