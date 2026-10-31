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
