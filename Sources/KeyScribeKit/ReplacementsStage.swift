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

// Post-STT text stage. Literal matches are case-insensitive and word-boundary constrained ("pipe" never
// replaces inside "pipeline"; use a regex rule for substring matching). Literal replacement text is inserted
// verbatim ($ / \ are not template refs); regex rules use NSRegularExpression template substitution ($1, \$).
// An invalid regex is skipped, not fatal. Runs before tokenization (design.md §4.2.1); not protected from a
// later LLM rewrite (design.md §4.2).
public struct ReplacementsStage: PipelineStage {
    public let position = StagePosition.postSTTText
    public let order = StageOrder.replacements
    public let rules: [ReplacementRule]

    // Regex + template resolved once at construction, so the per-dictation path is just matching. Invalid or
    // unsafe rules are dropped here.
    private let prepared: [(regex: NSRegularExpression, template: String)]

    // When the transform leaves text unchanged, the only possible whole-utterance owner is an *identity*
    // replacement (output == matched span); absent any such rule we skip the whole-utterance scan. A literal
    // rule is identity-capable iff heard == replace (case-insensitively); a regex can reproduce its input in
    // ways we can't cheaply rule out, so every regex is treated as identity-capable.
    private let mayHaveIdentityReplacement: Bool

    public init(rules: [ReplacementRule]) {
        self.rules = rules
        self.prepared = rules.compactMap { rule in
            if rule.isRegex {
                // Case-insensitive by default: match input is STT output, whose casing the engine chooses, so
                // a case-sensitive pattern would silently miss. Opt back in with an inline `(?-i)`.
                guard ReplacementSafety.isSafe(rule.heard),
                      let re = RegexCache.regex(rule.heard, options: [.caseInsensitive]) else { return nil }
                return (re, rule.replace)
            }
            guard let first = rule.heard.first, let last = rule.heard.last else { return nil }
            // `\b` only exists between a word and a non-word char, so wrapping a term whose edge is already
            // punctuation ("/resume", "c++") in `\b` makes it unmatchable. Anchor `\b` only on a word-char
            // edge; a punctuation/space edge stays a plain substring boundary. So "pipe" still skips
            // "pipeline" and a leading-space glue term (" at gmail dot com") still matches — both of which
            // `(?<!\w)…(?!\w)` would get wrong.
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
        // Skip the whole-utterance scan when text was unchanged and no identity replacement could own it.
        // Otherwise hand `transformed` in so owner-verification reuses it rather than re-running the battery.
        context.bareReplacement = (transformed != input || mayHaveIdentityReplacement)
            ? bareReplacement(for: input, transformedInput: transformed)
            : nil
    }

    // Transform only the plain runs between ⟦SN:…⟧ tokens so a rule can never rewrite a verbatim/clipboard
    // token body minted upstream (design.md §4.2).
    private func transform(_ text: String) -> String {
        SentinelText.mappingOutsideSentinels(text) { run in
            var result = run
            for rule in prepared {
                let range = NSRange(result.startIndex..., in: result)
                guard rule.regex.firstMatch(in: result, range: range) != nil else { continue }
                result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
            }
            return result
        }
    }

    // The verbatim value to insert when one rule owns the WHOLE utterance, else nil. A rule "owns" it when its
    // single match spans the entire core — input minus surrounding whitespace and trailing sentence
    // punctuation/space (so a stray STT "slash dog." still clamps). The clamped value is the rule's generated
    // output; we clamp only when running every rule over the core reproduces exactly that value, so a second
    // rule mutating the owner's output falls through to the normal path.
    public func bareReplacement(for input: String, transformedInput: String? = nil) -> String? {
        let (core, leading, trailing) = utteranceCore(of: input)
        guard !core.isEmpty else { return nil }
        // A protected token (verbatim/clipboard) means no single rule cleanly owns the utterance — fall
        // through rather than let a rule match across the opaque token.
        guard !SentinelText.containsSentinel(core) else { return nil }
        let coreRange = NSRange(core.startIndex..., in: core)
        for rule in prepared {
            guard let match = rule.regex.firstMatch(in: core, range: coreRange), match.range == coreRange else { continue }
            let generated = rule.regex.replacementString(for: match, in: core, offset: 0, template: rule.template)
            // Verify no later rule mutates the owner's output. When core == input, transform(input) already
            // equals transform(core), so reuse it rather than re-running the battery.
            let coreTransformed = (transformedInput != nil && core == input) ? transformedInput! : transform(core)
            return coreTransformed == generated ? leading + generated + trailing : nil
        }
        return nil
    }

    // Matches regex `\w` closely enough for boundary placement: ASCII/Unicode letters, digits, "_".
    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    // A LiveEdits control char (`\n` from "insert new line", `\t` from "insert tab") is command output, not
    // STT cruft: trim it off the core so a rule can own the words, then re-attach as `leading`/`trailing` so
    // the dictated newline/tab survives. Ordinary STT residue (whitespace, trailing `.!?`) is discarded.
    private static let liveEditControl: Set<Character> = ["\n", "\t"]
    private static let trailingCruft: Set<Character> = [".", "!", "?"]
    private func utteranceCore(of input: String) -> (core: String, leading: String, trailing: String) {
        let chars = Array(input)
        var lo = 0, hi = chars.count
        var leading = "", trailing = ""
        while lo < hi {
            let c = chars[lo]
            if Self.liveEditControl.contains(c) { leading.append(c); lo += 1 }
            else if c.isWhitespace { lo += 1 }
            else { break }
        }
        while hi > lo {
            let c = chars[hi - 1]
            if Self.liveEditControl.contains(c) { trailing.insert(c, at: trailing.startIndex); hi -= 1 }
            else if c.isWhitespace || Self.trailingCruft.contains(c) { hi -= 1 }
            else { break }
        }
        return (String(chars[lo..<hi]), leading, trailing)
    }
}
