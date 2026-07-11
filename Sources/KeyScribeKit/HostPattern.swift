import Foundation

// Builds a host-anchored URL regex from a plain domain the user typed in the friendly "Website…" field
// (UX2 phase 7a). Entering `github.com` means "the URL's host is github.com or a subdomain of it" — never a
// substring match. The stored constraint is still an ordinary `url_pattern` regex (schema unchanged); the
// resolver matches it unanchored over the FULL URL string (ModeResolver.regexFound), so the `^…` anchor and
// the host structure below do the work. Hand-written raw patterns keep today's unanchored substring
// semantics — two documented tiers.
public enum HostPattern {
    private static let prefix = "(?i)^[a-z][a-z0-9+.-]*://([^/?#]*\\.)?"
    private static let suffix = "([/:?#]|$)"

    // Accepts `https://github.com/foo` and `https://gist.github.com/x`; rejects `https://notgithub.com/`,
    // `https://github.com.evil.example/`, and `https://example.com/github.com`. The entered domain is escaped
    // so regex metacharacters in it are literal.
    public static func regex(forDomain domain: String) -> String? {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed.contains(".") else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        return prefix + escaped + suffix
    }

    // The inverse of `regex(forDomain:)`: recognizes exactly the shape that function emits and returns the
    // plain domain, so the friendly "Website…" tier can show `github.com`, never the generated regex. A
    // hand-written raw URL pattern does not match this shape and returns nil (it stays in the raw-regex tier).
    // The round-trip guard (`regex(forDomain: candidate) == pattern`) makes recognition exact.
    public static func domain(fromRegex pattern: String) -> String? {
        guard pattern.hasPrefix(prefix), pattern.hasSuffix(suffix) else { return nil }
        let escaped = pattern.dropFirst(prefix.count).dropLast(suffix.count)
        guard !escaped.isEmpty else { return nil }
        let candidate = escaped.replacingOccurrences(of: "\\", with: "")
        guard regex(forDomain: candidate) == pattern else { return nil }
        return candidate
    }
}
