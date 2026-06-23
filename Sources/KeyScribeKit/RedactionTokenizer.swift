import Foundation

// Best-effort redaction (design.md §4.2). Pattern-matches likely-sensitive spans and tokenizes
// them BEFORE the (possibly cloud) LLM, restoring after. Gated by the mode's privacy toggle at the
// call site, which also forces context off (§4.4) so the redacted transcript is the only user
// content that can leave. This is **best-effort** — pattern matching misses obfuscated or novel
// secrets — and the UX must never imply a guarantee. Over-matching is safe: a token is restored to
// its original after the LLM, so a false positive only means that span was not rewritten, never
// that the inserted text is wrong.
public enum RedactionTokenizer {
    private struct Detector {
        let pattern: String
        let options: NSRegularExpression.Options
        let validate: @Sendable (String) -> Bool
        // Lowercased literals that MUST appear (any one) in a real match. A cheap substring check over
        // the lowercased transcript skips the regex engine entirely when none are present — most
        // dictations contain none of these vendor prefixes, so most of the detector battery is skipped.
        // Empty = no cheap literal (digit/email patterns); always run.
        let requires: [String]
        init(
            _ pattern: String, options: NSRegularExpression.Options = [],
            requires: [String] = [],
            validate: @escaping @Sendable (String) -> Bool = { _ in true }
        ) {
            self.pattern = pattern
            self.options = options
            self.requires = requires
            self.validate = validate
        }
    }

    // Named vendor / structural secret patterns. Validators reject false positives (Luhn for cards,
    // mod-97 for IBANs); the high-entropy sweep below catches novel tokens the named patterns miss.
    // Order is informational only — overlaps resolve by earliest-then-longest at the call site.
    private static let detectors: [Detector] = [
        Detector(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, requires: ["@"]),         // email
        Detector(#"\b\d{3}-\d{2}-\d{4}\b"#),                                                   // US SSN
        Detector(#"\b(?:\+?1[ -]?)?\(?\d{3}\)?[ -]?\d{3}[ -]?\d{4}\b"#),                       // US phone
        Detector(#"\b(?:\d[ -]?){12,18}\d\b"#, validate: luhnValid),                           // payment card
        Detector(                                                                              // PEM private key
            #"-----BEGIN[A-Z ]*PRIVATE KEY-----[\s\S]+?-----END[A-Z ]*PRIVATE KEY-----"#,
            options: [.dotMatchesLineSeparators], requires: ["private key"]),
        Detector(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,             // JWT
            requires: ["eyj"]),
        Detector(#"\bsk-[A-Za-z0-9_-]{16,}"#, requires: ["sk-"]),                              // OpenAI-style key
        Detector(#"\b[rsp]k_(?:live|test)_[A-Za-z0-9]{16,}"#,                                  // Stripe key
            requires: ["k_live_", "k_test_"]),
        Detector(#"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[0-9A-Z]{16}\b"#,              // AWS access key id
            requires: ["akia", "asia", "agpa", "aida", "aroa", "anpa", "anva", "aipa"]),
        Detector(#"\bAIza[0-9A-Za-z_-]{35}\b"#, requires: ["aiza"]),                           // Google API key
        Detector(#"\b[0-9]+-[0-9a-z]{32}\.apps\.googleusercontent\.com\b"#,                    // Google OAuth client id
            requires: ["googleusercontent"]),
        Detector(#"\bya29\.[0-9A-Za-z._-]{20,}"#, requires: ["ya29."]),                        // Google OAuth access token
        Detector(#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#,                                           // GitHub token
            requires: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"]),
        Detector(#"\bgithub_pat_[A-Za-z0-9_]{22,}\b"#, requires: ["github_pat_"]),             // GitHub fine-grained PAT
        Detector(#"\bglpat-[A-Za-z0-9_-]{20,}"#, requires: ["glpat-"]),                         // GitLab PAT
        Detector(#"\bxox[baprs]-[A-Za-z0-9-]{10,}"#, requires: ["xox"]),                       // Slack token
        Detector(#"\bxapp-[0-9]-[A-Za-z0-9-]{10,}"#, requires: ["xapp-"]),                     // Slack app-level token
        Detector(#"\bREDACTED_VENDOR_TOKEN\b"#,                                   // vendor token
            requires: ["_", "_", "_", "_"]),
        Detector(#"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{16,}=*"#, requires: ["bearer"]),           // Authorization: Bearer …
        Detector(                                                                              // KEY = "value" assignment
            #"(?i)\b[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD|API)[A-Z0-9_]*\s*[=:]\s*["']?[^\s"']{6,}["']?"#,
            requires: ["key", "token", "secret", "password", "passwd", "pwd", "api"]),
    ]

    private struct Span {
        let range: Range<String.Index>
        let value: String
        let length: Int
        init(range: Range<String.Index>, value: String) {
            self.range = range
            self.value = value
            self.length = value.count
        }
    }

    public static func apply(_ text: String, into tokenizer: Tokenizer) -> String {
        let haystack = text.lowercased()
        var spans: [Span] = []
        for detector in detectors {
            if !detector.requires.isEmpty,
               !detector.requires.contains(where: { haystack.contains($0) }) { continue }
            guard let re = RegexCache.regex(detector.pattern, options: detector.options) else { continue }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range, in: text) else { continue }
                let value = String(text[r])
                if detector.validate(value) { spans.append(Span(range: r, value: value)) }
            }
        }
        spans.append(contentsOf: ibanSpans(text))
        spans.append(contentsOf: highEntropySpans(text))
        guard !spans.isEmpty else { return text }

        // Earliest start first; on a tie, longest match wins. Then keep non-overlapping greedily.
        spans.sort {
            $0.range.lowerBound != $1.range.lowerBound
                ? $0.range.lowerBound < $1.range.lowerBound
                : $0.length > $1.length
        }
        var kept: [(range: Range<String.Index>, value: String)] = []
        var lastUpper: String.Index?
        for span in spans {
            if let lu = lastUpper, span.range.lowerBound < lu { continue }
            kept.append((span.range, span.value))
            lastUpper = span.range.upperBound
        }
        return tokenizer.splice(text, spans: kept, type: .redact)
    }

    // IBANs allow letters, so a greedy regex over-extends into the following word and the validator
    // then rejects the over-long string. Match generously, then trim trailing space-separated groups
    // until mod-97 validates, tokenizing only the valid prefix (a prefix, so the range is exact).
    private static func ibanSpans(_ text: String) -> [Span] {
        guard let re = RegexCache.regex(#"\b[A-Z]{2}\d{2}(?:[ ]?[A-Za-z0-9]){11,40}"#) else { return [] }
        var spans: [Span] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            var groups = String(text[r]).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            while !groups.isEmpty {
                let prefix = groups.joined(separator: " ")
                if ibanValid(prefix) {
                    let upper = text.index(r.lowerBound, offsetBy: prefix.count)
                    spans.append(Span(range: r.lowerBound..<upper, value: prefix))
                    break
                }
                groups.removeLast()
            }
        }
        return spans
    }

    // Generic high-entropy fallback for novel/unbranded secrets (API keys, hashes) the named
    // patterns miss. Conservative: a long run over a secret-like charset that mixes letters and
    // digits and carries high Shannon entropy. Tuned to avoid prose; over-matching is harmless here
    // (restored verbatim) so the bar favours catching secrets.
    private static func highEntropySpans(_ text: String) -> [Span] {
        guard hasLongSecretRun(text) else { return [] }
        guard let re = RegexCache.regex(#"[A-Za-z0-9+/=_-]{24,}"#) else { return [] }
        var spans: [Span] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let value = String(text[r])
            if isHighEntropySecret(value) { spans.append(Span(range: r, value: value)) }
        }
        return spans
    }

    // Cheap single utf8 pass: is there a run of ≥minLength chars over the entropy charset? Lets the
    // entropy regex be skipped entirely on transcripts with no long token (the common case).
    private static func hasLongSecretRun(_ text: String, minLength: Int = 24) -> Bool {
        var run = 0
        for b in text.utf8 {
            switch b {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2F, 0x3D, 0x5F, 0x2D:
                run += 1
                if run >= minLength { return true }
            default:
                run = 0
            }
        }
        return false
    }

    static func isHighEntropySecret(_ s: String) -> Bool {
        guard s.count >= 24 else { return false }
        let hasLetter = s.contains { $0.isLetter }
        let hasDigit = s.contains { $0.isNumber }
        guard hasLetter, hasDigit else { return false }
        return shannonEntropy(s) >= 4.0
    }

    static func shannonEntropy(_ s: String) -> Double {
        var counts = [Int](repeating: 0, count: 256)
        var n = 0
        for b in s.utf8 { counts[Int(b)] += 1; n += 1 }
        guard n > 0 else { return 0 }
        let total = Double(n)
        var acc = 0.0
        for count in counts where count > 0 {
            let p = Double(count) / total
            acc -= p * log2(p)
        }
        return acc
    }

    static let luhnValid: @Sendable (String) -> Bool = { candidate in
        let digits = candidate.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    static let ibanValid: @Sendable (String) -> Bool = { candidate in
        let compact = candidate.replacingOccurrences(of: " ", with: "").uppercased()
        guard (15...34).contains(compact.count),
              compact.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for ch in rearranged {
            let value: Int
            if let d = ch.wholeNumberValue, ch.isNumber {
                value = d
            } else if let ascii = ch.asciiValue, ch.isLetter {
                value = Int(ascii - 65) + 10
            } else {
                return false
            }
            remainder = value < 10 ? (remainder * 10 + value) % 97 : (remainder * 100 + value) % 97
        }
        return remainder == 1
    }
}
