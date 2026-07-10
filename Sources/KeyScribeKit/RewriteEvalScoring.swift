import Foundation

public struct RewriteEvalCheckResult: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case nonEmpty
        case noPreamble
        case mustContain
        case mustNotContain
        case regexAbsent
        case tokens
        case contextEcho
        case maxWer
    }

    public let kind: Kind
    public let passed: Bool
    public let detail: String

    public init(kind: Kind, passed: Bool, detail: String = "") {
        self.kind = kind
        self.passed = passed
        self.detail = detail
    }
}

// Deterministic checks over one model output (no LLM judge). Universal checks (nonEmpty, noPreamble)
// always run; the others run only when the case supplies their inputs, so a result's absence means
// "not applicable", not "passed".
public enum RewriteEvalScoring {
    public static func score(output: String, for c: RewriteEvalCase) -> [RewriteEvalCheckResult] {
        var results: [RewriteEvalCheckResult] = []
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        results.append(.init(kind: .nonEmpty, passed: !trimmed.isEmpty))
        results.append(noPreamble(trimmed))

        if !c.checks.mustContain.isEmpty {
            let missing = c.checks.mustContain.filter { !output.contains($0) }
            results.append(.init(
                kind: .mustContain, passed: missing.isEmpty,
                detail: missing.joined(separator: ", ")))
        }
        if !c.checks.mustNotContain.isEmpty {
            let hits = c.checks.mustNotContain.filter {
                output.range(of: $0, options: .caseInsensitive) != nil
            }
            results.append(.init(
                kind: .mustNotContain, passed: hits.isEmpty,
                detail: hits.joined(separator: ", ")))
        }
        if !c.checks.regexAbsent.isEmpty {
            let hits = c.checks.regexAbsent.filter { pattern in
                guard let re = RegexCache.regex(pattern) else { return false }
                return re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) != nil
            }
            results.append(.init(
                kind: .regexAbsent, passed: hits.isEmpty,
                detail: hits.joined(separator: ", ")))
        }
        if !c.tokens.isEmpty {
            let verdict = ValidationGate.check(output: output, issuedTokens: c.tokens)
            results.append(.init(
                kind: .tokens, passed: verdict == .pass,
                detail: verdict == .pass ? "" : String(describing: verdict)))
        }
        if let echo = contextEcho(output: output, for: c) {
            results.append(echo)
        }
        if let reference = c.checks.reference, let bound = c.checks.maxWer {
            let wer = BenchmarkScoring.wer(reference: reference, hypothesis: output)
            results.append(.init(
                kind: .maxWer, passed: wer <= bound,
                detail: String(format: "wer=%.2f bound=%.2f", wer, bound)))
        }
        return results
    }

    // Heuristic: a preamble phrase, a code-fence wrap, or a whole-output quote wrap all mean the model
    // narrated instead of returning bare text. Corpus authors avoid transcripts that legitimately open
    // with these phrases.
    private static func noPreamble(_ trimmed: String) -> RewriteEvalCheckResult {
        let lower = trimmed.lowercased()
        let preambles = ["here is ", "here's ", "sure,", "sure!", "sure.", "certainly", "of course"]
        let failed = preambles.contains { lower.hasPrefix($0) }
            || trimmed.hasPrefix("```")
            || (trimmed.count > 1 && trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
        return .init(kind: .noPreamble, passed: !failed, detail: failed ? String(trimmed.prefix(60)) : "")
    }

    // Word trigrams that exist in the supplied context but not in the transcript must not surface in
    // the output — the "Hi Maria," failure class (prompt_design.md context fence).
    private static func contextEcho(output: String, for c: RewriteEvalCase) -> RewriteEvalCheckResult? {
        let context = [c.precedingText, c.selectedText].compactMap { $0 }.joined(separator: " ")
        guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let leaked = trigrams(context).subtracting(trigrams(c.transcript))
        let hits = leaked.intersection(trigrams(output))
        return .init(
            kind: .contextEcho, passed: hits.isEmpty,
            detail: hits.sorted().prefix(3).joined(separator: " | "))
    }

    private static func trigrams(_ s: String) -> Set<String> {
        let tokens = BenchmarkScoring.tokens(s)
        guard tokens.count >= 3 else { return [] }
        return Set((0...(tokens.count - 3)).map { tokens[$0...($0 + 2)].joined(separator: " ") })
    }
}
