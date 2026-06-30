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
            guard !rule.heard.isEmpty else { return nil }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: rule.heard))\\b"
            guard let re = RegexCache.regex(pattern, options: [.caseInsensitive]) else { return nil }
            return (re, NSRegularExpression.escapedTemplate(for: rule.replace))
        }
    }

    public func apply(_ context: inout PipelineContext) {
        let input = context.text
        context.text = transform(input)
        context.bareReplacement = bareReplacement(for: input)
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
    public func bareReplacement(for input: String) -> String? {
        let core = utteranceCore(of: input)
        guard !core.isEmpty else { return nil }
        let coreRange = NSRange(core.startIndex..., in: core)
        for rule in prepared {
            guard let match = rule.regex.firstMatch(in: core, range: coreRange), match.range == coreRange else { continue }
            let generated = rule.regex.replacementString(for: match, in: core, offset: 0, template: rule.template)
            return transform(core) == generated ? generated : nil
        }
        return nil
    }

    private func utteranceCore(of input: String) -> String {
        let cruft: Set<Character> = [".", "!", "?", " ", "\t", "\n", "\r"]
        var core = Substring(input.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = core.last, cruft.contains(last) { core = core.dropLast() }
        return String(core)
    }
}
