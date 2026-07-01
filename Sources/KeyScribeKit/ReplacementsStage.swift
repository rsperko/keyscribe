import Foundation

public struct ReplacementRule: Sendable, Equatable {
    public let heard: String
    public let replace: String
    public let isRegex: Bool

    public init(heard: String, replace: String, isRegex: Bool) {
        self.heard = heard
        self.replace = replace
        self.isRegex = isRegex
    }
}

// Post-STT text stage. Literal matches are case-insensitive and constrained to **word boundaries**
// — "pipe" never replaces inside "pipeline"; a user who wants substring/partial matching uses a
// regex rule (e.g. `pipe(.*)`). The literal replacement text is inserted verbatim ($ / \ are not
// template refs). Regex rules use NSRegularExpression with template substitution ($1 for capture
// groups, \$ for a literal $). An invalid regex is skipped rather than aborting the dictation.
// Replacements run before any tokenization (design.md §4.2.1) and are not protected from a later
// LLM rewrite (design.md §4.2).
public struct ReplacementsStage: PipelineStage {
    public let position = StagePosition.postSTTText
    public let order = StageOrder.replacements
    public let rules: [ReplacementRule]

    // Each rule's regex and substitution template resolved once at construction (the stage is built
    // per config generation and cached in ResolvedConfig), so the per-dictation path is just the match.
    // Pattern escaping, word-boundary wrapping, safety screening and compilation no longer run per
    // dictation per rule. Rules that resolve to nothing (empty literal, unsafe/invalid regex) are
    // dropped here exactly as the old per-call guards skipped them.
    private let prepared: [(regex: NSRegularExpression, template: String)]

    // A whole-utterance (bare) replacement is non-nil only when one rule owns the entire utterance —
    // which, for any rule whose output differs from the span it matched, necessarily changed the text.
    // So when the transform leaves the text untouched the only possible owner is an *identity*
    // replacement (output == matched span); absent any such rule we skip the whole-utterance scan
    // entirely. A literal rule is identity-capable iff heard == replace (case-insensitively, matching
    // the case-insensitive match); a regex template can reproduce its input in ways we cannot cheaply
    // rule out, so every regex rule is treated as identity-capable.
    private let mayHaveIdentityReplacement: Bool

    public init(rules: [ReplacementRule]) {
        self.rules = rules
        self.prepared = rules.compactMap { rule in
            if rule.isRegex {
                // Case-insensitive by default: the match input is STT output, whose casing the engine
                // chooses (it commonly capitalizes the first word), so a case-sensitive pattern would
                // silently miss. A power user opts back into case with an inline `(?-i)`.
                guard ReplacementSafety.isSafe(rule.heard),
                      let re = RegexCache.regex(rule.heard, options: [.caseInsensitive]) else { return nil }
                return (re, rule.replace)
            }
            guard let first = rule.heard.first, let last = rule.heard.last else { return nil }
            // A `\b` word boundary only exists between a word and a non-word character, so wrapping a
            // term whose edge is already punctuation (a slash-command "/resume", "c++") in `\b` makes
            // it unmatchable — `\b/` can never anchor at an utterance edge. Anchor the whole-word
            // boundary only on a word-character edge; a punctuation-or-space edge is left as a plain
            // substring boundary. So "pipe" still skips "pipeline", and a leading-space glue term
            // (" at gmail dot com") still matches — both of which `(?<!\w)…(?!\w)` would get wrong.
            let lead = Self.isWordCharacter(first) ? #"\b"# : ""
            let trail = Self.isWordCharacter(last) ? #"\b"# : ""
            let pattern = "\(lead)\(NSRegularExpression.escapedPattern(for: rule.heard))\(trail)"
            guard let re = RegexCache.regex(pattern, options: [.caseInsensitive]) else { return nil }
            return (re, NSRegularExpression.escapedTemplate(for: rule.replace))
        }
        self.mayHaveIdentityReplacement = rules.contains { rule in
            guard !rule.heard.isEmpty else { return false }
            return rule.isRegex || rule.heard.lowercased() == rule.replace.lowercased()
        }
    }

    public func apply(_ context: inout PipelineContext) {
        let input = context.text
        let transformed = transform(input)
        context.text = transformed
        // Skip the whole-utterance scan when the text was unchanged and no identity replacement could
        // own it. Otherwise hand `transformed` in so the owner-verification reuses it instead of
        // running the rule battery a third time.
        context.bareReplacement = (transformed != input || mayHaveIdentityReplacement)
            ? bareReplacement(for: input, transformedInput: transformed)
            : nil
    }

    private func transform(_ text: String) -> String {
        var result = text
        for rule in prepared {
            let range = NSRange(result.startIndex..., in: result)
            guard rule.regex.firstMatch(in: result, range: range) != nil else { continue }
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
        }
        return result
    }

    // The verbatim value to insert when one rule owns the WHOLE utterance, else nil. A rule "owns"
    // the utterance when its single match spans the entire core — the input minus surrounding
    // whitespace and a trailing run of sentence punctuation/space (so a stray STT "slash dog." still
    // clamps). The clamped value is the rule's GENERATED output (post-substitution for a regex), and
    // we only clamp when running every rule over the core reproduces exactly that value — so a second
    // rule mutating the owner's output conservatively falls through to the normal path.
    public func bareReplacement(for input: String, transformedInput: String? = nil) -> String? {
        let core = utteranceCore(of: input)
        guard !core.isEmpty else { return nil }
        let coreRange = NSRange(core.startIndex..., in: core)
        for rule in prepared {
            guard let match = rule.regex.firstMatch(in: core, range: coreRange), match.range == coreRange else { continue }
            let generated = rule.regex.replacementString(for: match, in: core, offset: 0, template: rule.template)
            // Verify no later rule mutates the owner's output. When the core is the whole input (no
            // surrounding whitespace/cruft), the caller's transform(input) already equals
            // transform(core), so reuse it rather than running the battery again.
            let coreTransformed = (transformedInput != nil && core == input) ? transformedInput! : transform(core)
            return coreTransformed == generated ? generated : nil
        }
        return nil
    }

    // Matches regex `\w` closely enough for boundary placement: ASCII/Unicode letters, digits, "_".
    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    private func utteranceCore(of input: String) -> String {
        let cruft: Set<Character> = [".", "!", "?", " ", "\t", "\n", "\r"]
        var core = Substring(input.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = core.last, cruft.contains(last) { core = core.dropLast() }
        return String(core)
    }
}
