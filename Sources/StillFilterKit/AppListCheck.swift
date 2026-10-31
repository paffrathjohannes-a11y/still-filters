import Foundation

/// Genaue Nachbildung der Prüfung, die die Still-App vor dem Übernehmen einer Server-Liste macht
/// (`RuleListCheck` in AdBlocker/AppCore/ServerLists.swift). Lehnt die App eine Liste ab, bleibt sie für alle
/// Nutzer auf dem alten Stand – deshalb muss jede veröffentlichte Liste diese Prüfung bestehen.
///
/// Ändert sich die Prüfung in der App, muss sie hier gleich mitgeändert werden (und umgekehrt).
public enum AppListCheck {
    public static let maxListBytes = 40 * 1024 * 1024
    public static let rulesLimit = 150_000

    /// Trigger, die eine Regel auf bestimmte Seiten, Ressourcen oder Ladearten eingrenzen
    public static let scopingTriggers = ["if-domain", "unless-domain", "if-top-url", "unless-top-url", "resource-type", "load-type"]

    /// Selektoren, die die ganze Seite ausblenden würden
    public static let pageSelectors: Set<String> = [
        "html", "body", ":root", "*",
        "html *", "body *", ":root *", "html > *", "body > *", ":root > *", "html>*", "body>*", ":root>*",
        "html body", "html > body", "html>body",
    ]

    public struct Problem: Equatable, Sendable, CustomStringConvertible {
        public let index: Int?
        public let reason: String
        public var description: String { index.map { "Regel \($0): \(reason)" } ?? reason }
    }

    /// Alle Gründe, aus denen die App diese Liste ablehnen würde (leer = App übernimmt sie).
    /// `expectedRules`: Regelzahl laut manifest.json; nil = nicht prüfen.
    public static func problems(_ data: Data, expectedRules: Int?) -> [Problem] {
        guard data.count <= maxListBytes else { return [Problem(index: nil, reason: "größer als \(maxListBytes) Bytes")] }
        guard let rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return [Problem(index: nil, reason: "kein JSON-Array aus Regeln")]
        }
        var problems: [Problem] = []
        if let expectedRules, rules.count != expectedRules {
            problems.append(Problem(index: nil, reason: "\(rules.count) Regeln, laut Manifest \(expectedRules)"))
        }
        if rules.count > rulesLimit { problems.append(Problem(index: nil, reason: "\(rules.count) Regeln über \(rulesLimit)")) }
        for (index, rule) in rules.enumerated() {
            guard let trigger = rule["trigger"] as? [String: Any], let action = rule["action"] as? [String: Any],
                  let type = action["type"] as? String
            else {
                problems.append(Problem(index: index, reason: "Regel ohne trigger/action"))
                continue
            }
            switch type {
            case "block":
                let scoped = scopingTriggers.contains { trigger[$0] != nil }
                if !scoped, let filter = trigger["url-filter"] as? String, matchesEverything(filter) {
                    problems.append(Problem(index: index, reason: "block mit url-filter „\(filter)“ ohne Eingrenzung"))
                }
            case "css-display-none":
                if let selector = action["selector"] as? String, hidesWholePage(selector) {
                    problems.append(Problem(index: index, reason: "Ausblenden der ganzen Seite: „\(selector.prefix(80))“"))
                }
            default:
                break
            }
        }
        return problems
    }

    /// url-filter, der praktisch jede Adresse trifft, z. B. `.*`, `^https?://`, `^https?://.*/`
    public static func matchesEverything(_ filter: String) -> Bool {
        var rest = Substring(filter)
        if rest.hasPrefix("^") { rest = rest.dropFirst() }
        for scheme in ["https?://", "https?:\\/\\/", "https://", "http://", "https?:", "[a-z]+://", "[^:]+://"] where rest.hasPrefix(scheme) {
            rest = rest.dropFirst(scheme.count)
            break
        }
        let everything: Set<String> = ["", ".*", ".+", "/", ".*/", "/.*", ".*/.*", "$", ".*$", "[^/]*", "[^/]+", "[^/]*/", "[^/]+/", "[^/]+/.*", "[^/]*/.*"]
        return everything.contains(String(rest))
    }

    /// Selektorliste enthält einen Selektor, der die ganze Seite ausblendet (`html`, `body`, `:root`, `*` …)
    public static func hidesWholePage(_ selectorList: String) -> Bool {
        var depth = 0
        var current = ""
        var parts: [String] = []
        for char in selectorList {
            switch char {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            case "," where depth == 0:
                parts.append(current)
                current = ""
                continue
            default: break
            }
            current.append(char)
        }
        parts.append(current)
        return parts.contains { part in
            let normalized = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return pageSelectors.contains(normalized)
        }
    }
}
