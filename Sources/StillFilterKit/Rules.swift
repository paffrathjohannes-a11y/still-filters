import Foundation

/// Ressourcentypen, die Safari-Content-Blocker kennen.
public enum ResourceType: String, CaseIterable, Codable, Sendable {
    case document, image, styleSheet = "style-sheet", script, font, raw, media, popup, ping, websocket, other
}

/// Netzwerkregel in EasyList-/AdGuard-Syntax, z. B. `||werbung.de^$third-party,script`.
public struct NetworkRule: Equatable, Sendable {
    public var isException = false
    public var pattern = ""
    public var isRegex = false
    public var matchCase = false
    /// nil = beliebig, true = nur Drittanbieter, false = nur Erstanbieter
    public var thirdParty: Bool?
    /// leer = alle Typen
    public var resourceTypes: Set<ResourceType> = []
    /// Unterframes (`$subdocument`) sind in Safari `document` mit `load-context: child-frame`
    public var childFrameOnly = false
    public var includeDomains: [String] = []
    public var excludeDomains: [String] = []
    public var important = false
    /// Nur für Ausnahmen: hebt alles auf der Seite auf (`$document`) bzw. nur Ausblende-Regeln
    public var exceptionScope: ExceptionScope = .requests

    public enum ExceptionScope: Sendable { case requests, document, elementHiding, genericHiding }
}

/// Ausblende-Regel, z. B. `example.com##.banner`.
public struct CosmeticRule: Equatable, Sendable {
    public var isException = false
    public var includeDomains: [String] = []
    public var excludeDomains: [String] = []
    public var selector = ""
}

public enum ParsedRule: Equatable, Sendable {
    case network(NetworkRule)
    case cosmetic(CosmeticRule)
    case unsupported(String)
    case comment
}

/// Liest einzelne Zeilen einer Filterliste. Was Safari nicht abbilden kann, wird als `.unsupported(Grund)`
/// gemeldet statt still verworfen, damit die Abdeckung messbar bleibt.
public enum RuleParser {
    public static func parse(_ raw: Substring) -> ParsedRule {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { return .comment }

        if let cosmetic = cosmeticMarker(in: line) {
            return parseCosmetic(line, marker: cosmetic)
        }
        if line.hasPrefix("#") { return .comment }

        // Hosts-Format („0.0.0.0 domain“) und reine Domains
        if line.hasPrefix("0.0.0.0 ") || line.hasPrefix("127.0.0.1 ") {
            let host = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            return host.isEmpty || host == "0.0.0.0" ? .comment : .network(NetworkRule(pattern: "||\(host)^"))
        }
        if isBareDomain(line) {
            return .network(NetworkRule(pattern: "||\(line)^"))
        }
        return parseNetwork(line)
    }

    // MARK: - Ausblende-Regeln

    private struct Marker { let range: Range<String.Index>; let kind: String }

    private static let markers = ["#@?#", "#@$#", "#@%#", "#?#", "#$#", "#%#", "#@#", "##", "$@$", "$$"]

    private static func cosmeticMarker(in line: String) -> Marker? {
        guard let hash = line.firstIndex(where: { $0 == "#" || $0 == "$" }) else { return nil }
        var index = hash
        while index < line.endIndex {
            for marker in markers where line[index...].hasPrefix(marker) {
                let prefix = line[..<index]
                // Netzwerkregeln enthalten Pfade/Optionen; ein Domain-Präfix nie „/“, „|“ oder „^“
                guard !prefix.contains(where: { "/|^=*".contains($0) }) else { return nil }
                return Marker(range: index..<line.index(index, offsetBy: marker.count), kind: marker)
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static let proceduralPseudo = [
        ":has-text(", ":-abp-", ":contains(", ":xpath(", ":upward(", ":remove(", ":style(", ":matches-css",
        ":min-text-length(", ":watch-attr(", ":matches-path(", ":others(", ":if(", ":if-not(", ":nth-ancestor(",
        ":matches-attr(", ":matches-property(", ":remove-attr(", ":remove-class(", ":matches-media(", ":shadow(",
    ]

    private static func parseCosmetic(_ line: String, marker: Marker) -> ParsedRule {
        switch marker.kind {
        case "##", "#@#": break
        case "#?#", "#@?#": return .unsupported("extended-css")
        case "#$#", "#@$#": return .unsupported("css-injection")
        case "#%#", "#@%#": return .unsupported("javascript")
        default: return .unsupported("html-filter")
        }
        let selector = String(line[marker.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if selector.hasPrefix("+js(") { return .unsupported("scriptlet") }
        if selector.isEmpty { return .unsupported("empty-selector") }
        let lower = selector.lowercased()
        if proceduralPseudo.contains(where: { lower.contains($0) }) { return .unsupported("procedural-selector") }
        guard SelectorCheck.isPlausible(selector) else { return .unsupported("invalid-selector") }

        var rule = CosmeticRule(isException: marker.kind == "#@#", selector: selector)
        let domains = line[..<marker.range.lowerBound]
        for raw in domains.split(separator: ",") {
            var domain = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = domain.hasPrefix("~")
            if negated { domain.removeFirst() }
            guard let valid = DomainCheck.normalize(domain) else { return .unsupported("domain-format") }
            if negated { rule.excludeDomains.append(valid) } else { rule.includeDomains.append(valid) }
        }
        return .cosmetic(rule)
    }

    // MARK: - Netzwerkregeln

    private static func parseNetwork(_ line: String) -> ParsedRule {
        var rule = NetworkRule()
        var text = Substring(line)
        if text.hasPrefix("@@") {
            rule.isException = true
            text = text.dropFirst(2)
        }

        var options: [Substring] = []
        if let dollar = optionsSeparator(in: text) {
            options = text[text.index(after: dollar)...].split(separator: ",")
            text = text[..<dollar]
        }

        if text.count > 2, text.hasPrefix("/"), text.hasSuffix("/") {
            rule.isRegex = true
            rule.pattern = String(text.dropFirst().dropLast())
        } else {
            rule.pattern = String(text)
        }

        var include: Set<ResourceType> = []
        var exclude: Set<ResourceType> = []
        for rawOption in options {
            var option = rawOption.lowercased()
            let negated = option.hasPrefix("~")
            if negated { option.removeFirst() }

            if option.hasPrefix("domain=") || option.hasPrefix("from=") {
                let value = option[option.index(after: option.firstIndex(of: "=")!)...]
                for raw in value.split(separator: "|") {
                    var domain = String(raw)
                    let excluded = domain.hasPrefix("~")
                    if excluded { domain.removeFirst() }
                    guard let valid = DomainCheck.normalize(domain) else { return .unsupported("domain-format") }
                    if excluded { rule.excludeDomains.append(valid) } else { rule.includeDomains.append(valid) }
                }
                continue
            }

            switch option {
            case "third-party", "3p":
                rule.thirdParty = !negated
            case "first-party", "1p":
                rule.thirdParty = negated
            case "match-case":
                rule.matchCase = !negated
            case "important":
                rule.important = true
            case "all":
                include.formUnion(ResourceType.allCases)
            case "document", "doc":
                if rule.isException {
                    rule.exceptionScope = .document
                } else if negated {
                    exclude.insert(.document)
                } else {
                    include.insert(.document)
                }
            case "elemhide", "ehide":
                guard rule.isException else { return .unsupported("option-elemhide") }
                rule.exceptionScope = .elementHiding
            case "generichide", "ghide":
                guard rule.isException else { return .unsupported("option-generichide") }
                rule.exceptionScope = .genericHiding
            case "subdocument", "frame":
                if negated { exclude.insert(.document) } else { include.insert(.document); rule.childFrameOnly = true }
            default:
                guard let type = resourceType(option) else { return .unsupported("option-\(option)") }
                if negated { exclude.insert(type) } else { include.insert(type) }
            }
        }

        if !exclude.isEmpty {
            // Safari kennt keine Verneinung: Komplement bilden
            let base = include.isEmpty ? Set(ResourceType.allCases).subtracting([.popup]) : include
            include = base.subtracting(exclude)
            if include.isEmpty { return .unsupported("empty-types") }
        }
        rule.resourceTypes = include
        if rule.childFrameOnly && include != [.document] { rule.childFrameOnly = false }

        if !rule.includeDomains.isEmpty && !rule.excludeDomains.isEmpty {
            return .unsupported("mixed-domains")
        }
        if rule.pattern.isEmpty || rule.pattern == "*" {
            if rule.includeDomains.isEmpty && rule.excludeDomains.isEmpty && rule.exceptionScope == .requests && !rule.isException {
                return .unsupported("too-generic")
            }
        }
        return .network(rule)
    }

    /// Letztes „$“, nach dem nur noch Optionen stehen (Regex-Regeln können selbst „$“ enthalten).
    private static func optionsSeparator(in text: Substring) -> Substring.Index? {
        guard let dollar = text.lastIndex(of: "$") else { return nil }
        let tail = text[text.index(after: dollar)...]
        if tail.isEmpty { return nil }
        if text.hasPrefix("/"), text[..<dollar].hasSuffix("/") == false, text.hasSuffix("/") { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~=,|.*:/")
        return tail.unicodeScalars.allSatisfy(allowed.contains) ? dollar : nil
    }

    private static func resourceType(_ option: String) -> ResourceType? {
        switch option {
        case "script": return .script
        case "image": return .image
        case "stylesheet", "css": return .styleSheet
        case "font": return .font
        case "media": return .media
        case "xmlhttprequest", "xhr": return .raw
        case "websocket": return .websocket
        case "ping", "beacon": return .ping
        case "popup": return .popup
        case "object", "object-subrequest", "other": return .other
        default: return nil
        }
    }

    private static func isBareDomain(_ line: String) -> Bool {
        line.contains(".") && !line.contains("/") && !line.contains("$") && !line.contains("^") && !line.contains("|")
            && !line.contains("*") && !line.contains("#") && !line.contains(" ") && DomainCheck.normalize(line) != nil
    }
}

enum DomainCheck {
    /// Kleinbuchstaben, nur ASCII, keine Platzhalter (Safari kennt nur „alle Subdomains“)
    static func normalize(_ domain: String) -> String? {
        let lower = domain.lowercased()
        guard !lower.isEmpty, lower.count < 254, !lower.hasSuffix(".*"), !lower.hasPrefix("/"),
              lower.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_").contains($0) }),
              lower.contains(".") || lower == "localhost"
        else { return nil }
        return lower
    }
}

enum SelectorCheck {
    /// Grobe Plausibilitätsprüfung. Ein einziger ungültiger Selektor lässt WebKit die ganze Liste ablehnen;
    /// die endgültige Prüfung macht `still-check validate` mit echtem WebKit.
    static func isPlausible(_ selector: String) -> Bool {
        guard !selector.contains("{"), !selector.contains("}"), !selector.contains(";"),
              !selector.hasPrefix(","), !selector.hasSuffix(","), !selector.hasSuffix(" "),
              selector.unicodeScalars.allSatisfy({ $0.isASCII })
        else { return false }
        var depth = (paren: 0, bracket: 0)
        var quote: Character?
        for char in selector {
            if let open = quote {
                if char == open { quote = nil }
                continue
            }
            switch char {
            case "\"", "'": quote = char
            case "(": depth.paren += 1
            case ")": depth.paren -= 1
            case "[": depth.bracket += 1
            case "]": depth.bracket -= 1
            default: break
            }
            if depth.paren < 0 || depth.bracket < 0 { return false }
        }
        return quote == nil && depth == (0, 0)
    }
}
