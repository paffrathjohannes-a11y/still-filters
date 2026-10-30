import Foundation

/// Eine Regel im Safari-Content-Blocker-Format (WebKit `WKContentRuleList`).
public struct SafariRule: Codable, Equatable, Sendable {
    public struct Trigger: Codable, Equatable, Sendable {
        public var urlFilter: String
        public var caseSensitive: Bool?
        public var ifDomain: [String]?
        public var unlessDomain: [String]?
        public var ifTopURL: [String]?
        public var resourceType: [String]?
        public var loadType: [String]?
        public var loadContext: [String]?

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case caseSensitive = "url-filter-is-case-sensitive"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case ifTopURL = "if-top-url"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case loadContext = "load-context"
        }
    }

    public struct Action: Codable, Equatable, Sendable {
        public var type: String
        public var selector: String?
    }

    public var trigger: Trigger
    public var action: Action
}

public struct ConversionStats: Codable, Sendable {
    public var sourceLines = 0
    public var networkRules = 0
    public var cosmeticRules = 0
    public var badfilterRemoved = 0
    /// Grund → Anzahl, z. B. `option-redirect`, `scriptlet`, `pattern`
    public var unsupported: [String: Int] = [:]
    /// Ausnahmen, die Safari nur näherungsweise abbilden kann
    public var approximated = 0
    public var safariRules = 0
    public var discardedOverLimit = 0

    public var unsupportedTotal: Int { unsupported.values.reduce(0, +) }
}

public struct ConversionResult: Sendable {
    public let rules: [SafariRule]
    public let stats: ConversionStats

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(rules), as: UTF8.self)
    }
}

/// Wandelt Filterlisten in Safari-Content-Blocker-Regeln um.
///
/// Safari wendet Regeln der Reihe nach an; `ignore-previous-rules` hebt alles davor auf. Daher die feste
/// Reihenfolge: allgemeines Ausblenden → `$generichide` → seitenbezogenes Ausblenden → `$elemhide` →
/// Netzwerksperren → Ausnahmen → `$important` → seitenweite Ausnahmen (`$document`).
public enum SafariConverter {
    public static let safariRuleLimit = 150_000
    /// Selektoren je Ausblende-Regel: weniger Regeln, ohne WebKit beim Kompilieren zu überfordern
    static let selectorsPerRule = 250

    public static func convert(lines: [Substring], maxRules: Int = safariRuleLimit) -> ConversionResult {
        var stats = ConversionStats()
        stats.sourceLines = lines.count

        let disabled = badfilterTargets(lines)
        var network: [NetworkRule] = []
        var cosmetic: [CosmeticRule] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if disabled.contains(trimmed) { stats.badfilterRemoved += 1; continue }
            if trimmed.contains("badfilter") && isBadfilter(trimmed) { continue }
            switch RuleParser.parse(line) {
            case .network(let rule): network.append(rule)
            case .cosmetic(let rule): cosmetic.append(rule)
            case .unsupported(let reason): stats.unsupported[reason, default: 0] += 1
            case .comment: break
            }
        }
        stats.networkRules = network.count
        stats.cosmeticRules = cosmetic.count

        var generic: [SafariRule] = []
        var specific: [SafariRule] = []
        buildCosmetic(cosmetic, generic: &generic, specific: &specific, stats: &stats)

        var genericHideExceptions: [SafariRule] = []
        var elementHideExceptions: [SafariRule] = []
        var blocks: [SafariRule] = []
        var exceptions: [SafariRule] = []
        var importantBlocks: [SafariRule] = []
        var importantExceptions: [SafariRule] = []
        var documentExceptions: [SafariRule] = []

        for rule in network {
            if rule.isException && rule.exceptionScope != .requests {
                guard let page = pageTrigger(for: rule) else { stats.unsupported["pattern", default: 0] += 1; continue }
                let ignore = SafariRule(trigger: page, action: .init(type: "ignore-previous-rules"))
                switch rule.exceptionScope {
                case .document: documentExceptions.append(ignore)
                case .elementHiding: elementHideExceptions.append(ignore)
                case .genericHiding: genericHideExceptions.append(ignore)
                case .requests: break
                }
                continue
            }
            guard let trigger = requestTrigger(for: rule) else { stats.unsupported["pattern", default: 0] += 1; continue }
            let safari = SafariRule(trigger: trigger, action: .init(type: rule.isException ? "ignore-previous-rules" : "block"))
            switch (rule.isException, rule.important) {
            case (false, false): blocks.append(safari)
            case (true, false): exceptions.append(safari)
            case (false, true): importantBlocks.append(safari)
            case (true, true): importantExceptions.append(safari)
            }
        }

        // Über dem Limit fallen zuerst einfache Netzwerksperren vom Ende weg, nie Ausnahmen
        let fixed = generic.count + genericHideExceptions.count + specific.count + elementHideExceptions.count
            + exceptions.count + importantBlocks.count + importantExceptions.count + documentExceptions.count
        let room = max(0, maxRules - fixed)
        if blocks.count > room {
            stats.discardedOverLimit = blocks.count - room
            blocks.removeLast(blocks.count - room)
        }

        let rules = generic + genericHideExceptions + specific + elementHideExceptions
            + blocks + exceptions + importantBlocks + importantExceptions + documentExceptions
        stats.safariRules = rules.count
        return ConversionResult(rules: rules, stats: stats)
    }

    // MARK: - Ausblende-Regeln

    private static func buildCosmetic(_ rules: [CosmeticRule], generic: inout [SafariRule],
                                      specific: inout [SafariRule], stats: inout ConversionStats) {
        var genericExcludes: [String: Set<String>] = [:]   // Selektor → Domains, auf denen er nicht gilt
        var specificIncludes: [String: Set<String>] = [:]  // Selektor → Domains, auf denen er gilt
        var removedEverywhere: Set<String> = []

        for rule in rules where !rule.isException {
            if rule.includeDomains.isEmpty {
                genericExcludes[rule.selector, default: []].formUnion(rule.excludeDomains)
            } else {
                specificIncludes[rule.selector, default: []].formUnion(rule.includeDomains)
                if !rule.excludeDomains.isEmpty { stats.approximated += 1 }
            }
        }
        for rule in rules where rule.isException {
            if rule.includeDomains.isEmpty {
                removedEverywhere.insert(rule.selector)
                continue
            }
            if genericExcludes[rule.selector] != nil {
                genericExcludes[rule.selector]!.formUnion(rule.includeDomains)
            }
            if var include = specificIncludes[rule.selector] {
                include.subtract(rule.includeDomains)
                specificIncludes[rule.selector] = include.isEmpty ? nil : include
            }
        }
        for selector in removedEverywhere {
            genericExcludes[selector] = nil
            specificIncludes[selector] = nil
        }

        // Gleiche Domainlisten bündeln, sortiert für reproduzierbare Ausgabe
        var genericGroups: [[String]: [String]] = [:]
        for (selector, excludes) in genericExcludes { genericGroups[excludes.sorted(), default: []].append(selector) }
        for (excludes, selectors) in genericGroups.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            for batch in selectors.sorted().chunked(selectorsPerRule) {
                var trigger = SafariRule.Trigger(urlFilter: ".*")
                if !excludes.isEmpty { trigger.unlessDomain = excludes.map { "*" + $0 } }
                generic.append(SafariRule(trigger: trigger, action: .init(type: "css-display-none", selector: batch.joined(separator: ", "))))
            }
        }

        var specificGroups: [[String]: [String]] = [:]
        for (selector, includes) in specificIncludes { specificGroups[includes.sorted(), default: []].append(selector) }
        for (includes, selectors) in specificGroups.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            for batch in selectors.sorted().chunked(selectorsPerRule) {
                var trigger = SafariRule.Trigger(urlFilter: ".*")
                trigger.ifDomain = includes.map { "*" + $0 }
                specific.append(SafariRule(trigger: trigger, action: .init(type: "css-display-none", selector: batch.joined(separator: ", "))))
            }
        }
    }

    // MARK: - Netzwerkregeln

    static func requestTrigger(for rule: NetworkRule) -> SafariRule.Trigger? {
        guard let filter = URLPattern.regex(for: rule) else { return nil }
        var trigger = SafariRule.Trigger(urlFilter: filter)
        if rule.matchCase { trigger.caseSensitive = true }
        if !rule.includeDomains.isEmpty { trigger.ifDomain = rule.includeDomains.map { "*" + $0 } }
        if !rule.excludeDomains.isEmpty { trigger.unlessDomain = rule.excludeDomains.map { "*" + $0 } }
        if let thirdParty = rule.thirdParty { trigger.loadType = [thirdParty ? "third-party" : "first-party"] }
        if !rule.resourceTypes.isEmpty {
            trigger.resourceType = rule.resourceTypes.map(\.rawValue).sorted()
        }
        if rule.childFrameOnly { trigger.loadContext = ["child-frame"] }
        return trigger
    }

    /// Ausnahmen für ganze Seiten (`$document`, `$elemhide`) greifen über die Seiten-Domain, nicht über die
    /// URL der einzelnen Anfrage.
    static func pageTrigger(for rule: NetworkRule) -> SafariRule.Trigger? {
        var trigger = SafariRule.Trigger(urlFilter: ".*")
        if let host = plainHost(rule.pattern) {
            trigger.ifDomain = ["*" + host]
        } else if !rule.includeDomains.isEmpty {
            trigger.ifDomain = rule.includeDomains.map { "*" + $0 }
        } else if let filter = URLPattern.regex(for: rule), filter != ".*" {
            trigger.ifTopURL = [filter]
        } else {
            return nil
        }
        return trigger
    }

    /// `||example.com^` bzw. `||example.com` → `example.com`
    static func plainHost(_ pattern: String) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var host = pattern.dropFirst(2)
        if host.hasSuffix("^") || host.hasSuffix("/") { host = host.dropLast() }
        return DomainCheck.normalize(String(host))
    }

    // MARK: - $badfilter

    private static func isBadfilter(_ line: String) -> Bool {
        guard let dollar = line.lastIndex(of: "$") else { return false }
        return line[line.index(after: dollar)...].split(separator: ",").contains("badfilter")
    }

    /// `$badfilter` schaltet die gleichnamige Regel ohne diese Option ab.
    private static func badfilterTargets(_ lines: [Substring]) -> Set<String> {
        var targets: Set<String> = []
        for line in lines where line.contains("badfilter") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard isBadfilter(text), let dollar = text.lastIndex(of: "$") else { continue }
            let options = text[text.index(after: dollar)...].split(separator: ",").filter { $0 != "badfilter" }
            let base = String(text[..<dollar])
            targets.insert(options.isEmpty ? base : base + "$" + options.joined(separator: ","))
        }
        return targets
    }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
