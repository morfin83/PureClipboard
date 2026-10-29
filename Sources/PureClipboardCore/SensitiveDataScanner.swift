import Foundation

/// Conservative detector for secrets in text that is about to reach the clipboard.
/// It reports only rule names, never the matched content, and errs on the side of blocking.
public enum SensitiveDataScanner {
    private struct Rule {
        let name: String
        let pattern: String
        var options: NSRegularExpression.Options = []
    }

    private static let keyWords = "password|passwd|passphrase|pwd|secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|client[_-]?key|key[_-]?data|client[_-]?secret|auth[_-]?token|credential"

    private static let rules: [Rule] = [
        Rule(name: "private-key", pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----|PuTTY-User-Key-File"#),
        Rule(name: "aws-access-key", pattern: #"\b(AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA)[A-Z0-9]{16}\b"#),
        Rule(name: "github-token", pattern: #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}"#),
        Rule(name: "slack-token", pattern: #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
        Rule(name: "api-key-sk", pattern: #"\bsk-[A-Za-z0-9_-]{20,}"#),
        Rule(name: "google-api-key", pattern: #"\bAIza[0-9A-Za-z_-]{35}"#),
        Rule(name: "stripe-key", pattern: #"\b[sr]k_(live|test)_[A-Za-z0-9]{16,}"#),
        Rule(name: "jwt", pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        Rule(name: "authorization-header", pattern: #"\b(proxy-)?authorization\s*[:=]\s*["']?(bearer|basic|token)\s+\S{8,}"#, options: [.caseInsensitive]),
        Rule(name: "bearer-token", pattern: #"\bbearer\s+[A-Za-z0-9._~+/=-]{20,}"#, options: [.caseInsensitive]),
        Rule(name: "url-credentials", pattern: #"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s/:@]+:[^\s/@]{3,}@"#),
    ]

    private static let assignmentPattern =
        "\\b[\\w.-]*(?:\(keyWords))[\\w.-]*[\"']?\\s*[:=]\\s*[\"']?([^\\s\"'`,;]{8,})"

    private static let placeholderPrefixes = ["$", "<", "{", "[", "%", "*", "(", "#", "@"]
    private static let placeholderWords = [
        "example", "changeme", "redacted", "placeholder", "your", "xxxx", "••••", "process.env", "os.environ",
        "getenv", "secrets.", "config.", "settings.", "input", "password", "undefined", "optional", "string",
    ]

    /// Returns the sorted, de-duplicated names of the rules that matched. Empty means nothing suspicious found.
    public static func scan(_ text: String) -> [String] {
        var hits = Set<String>()
        let whole = NSRange(text.startIndex..., in: text)

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else {
                hits.insert("scanner-error")
                continue
            }
            if regex.firstMatch(in: text, range: whole) != nil { hits.insert(rule.name) }
        }

        if let regex = try? NSRegularExpression(pattern: assignmentPattern, options: [.caseInsensitive]) {
            for match in regex.matches(in: text, range: whole) where match.numberOfRanges > 1 {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                if !looksLikePlaceholder(String(text[range])) {
                    hits.insert("secret-assignment")
                    break
                }
            }
        } else {
            hits.insert("scanner-error")
        }

        if containsHighEntropyToken(text) { hits.insert("high-entropy-token") }
        return hits.sorted()
    }

    private static func looksLikePlaceholder(_ value: String) -> Bool {
        let lower = value.lowercased()
        if placeholderPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        if placeholderWords.contains(where: { lower.contains($0) }) { return true }
        if value.contains("(") || value.contains(")") { return true }
        if Set(lower).count <= 2 { return true }
        return false
    }

    private static func containsHighEntropyToken(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9+/_=-]{32,}"#) else { return true }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range])
            if token.hasPrefix("/") { continue }
            let hasUpper = token.contains { $0.isASCII && $0.isUppercase }
            let hasLower = token.contains { $0.isASCII && $0.isLowercase }
            let hasDigit = token.contains { $0.isASCII && $0.isNumber }
            guard hasUpper, hasLower, hasDigit else { continue }
            if shannonEntropy(token) >= 4.2 { return true }
        }
        return false
    }

    static func shannonEntropy(_ value: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in value { counts[character, default: 0] += 1 }
        let total = Double(value.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }
}
