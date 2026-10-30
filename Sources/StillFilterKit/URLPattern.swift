import Foundation

/// Übersetzt Filtermuster (`||host^`, `|https://`, `*`) in den Regex-Dialekt von Safari-Content-Blockern.
///
/// WebKit kennt nur `.`, `*`, `+`, `?`, Zeichenklassen `[]`, Gruppen `()` und die Anker `^`/`$`;
/// keine Alternativen (`|`), keine Wiederholungen `{n}`, keine Kürzel wie `\d`. Muster, die sich so
/// nicht ausdrücken lassen, liefern `nil` und werden als nicht unterstützt gezählt.
public enum URLPattern {
    /// Beliebiges Schema, optional beliebige Subdomains (entspricht `||`)
    static let domainAnchor = "^[^:]+://+([^:/]+\\.)?"

    public static func regex(for rule: NetworkRule) -> String? {
        rule.isRegex ? convertRegex(rule.pattern) : convertPattern(rule.pattern)
    }

    static func convertPattern(_ pattern: String) -> String? {
        guard pattern.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        var rest = Substring(pattern)
        var out = ""
        var inHost = false

        if rest.hasPrefix("||") {
            out = domainAnchor
            rest = rest.dropFirst(2)
            inHost = true
        } else if rest.hasPrefix("|") {
            out = "^"
            rest = rest.dropFirst()
        }
        var endAnchor = false
        if rest.hasSuffix("|") {
            endAnchor = true
            rest = rest.dropLast()
        }

        for char in rest {
            switch char {
            case "*":
                out += ".*"
                inHost = false
            case "^":
                // Trennzeichen: hinter dem Hostnamen folgt immer „/“ oder „:“ (Port)
                out += inHost ? "[/:]" : "[/:&?=]"
                inHost = false
            case "/", "?", "=", "&", ":":
                inHost = false
                out += char == "?" ? "\\?" : String(char)
            case ".", "+", "(", ")", "[", "]", "{", "}", "\\", "$":
                out += "\\" + String(char)
            case "|":
                return nil
            default:
                out.append(char)
            }
        }
        if endAnchor { out += "$" }

        while out.hasPrefix(".*") { out.removeFirst(2) }
        while out.hasSuffix(".*") && !out.hasSuffix("\\.*") { out.removeLast(2) }
        return out.isEmpty ? ".*" : out
    }

    static func convertRegex(_ pattern: String) -> String? {
        guard pattern.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        let forbidden = ["|", "{", "\\d", "\\D", "\\w", "\\W", "\\s", "\\S", "\\b", "\\B", "(?", "\\/"]
        if forbidden.contains(where: pattern.contains) {
            // „\/“ ist nur ein maskierter Schrägstrich und lässt sich ersetzen
            let unescaped = pattern.replacingOccurrences(of: "\\/", with: "/")
            if forbidden.dropLast().contains(where: unescaped.contains) { return nil }
            return unescaped
        }
        return pattern
    }
}
