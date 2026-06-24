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
                guard ReplacementSafety.isSafe(rule.heard), let re = RegexCache.regex(rule.heard) else { return nil }
                return (re, rule.replace)
            }
            guard !rule.heard.isEmpty else { return nil }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: rule.heard))\\b"
            guard let re = RegexCache.regex(pattern, options: [.caseInsensitive]) else { return nil }
            return (re, NSRegularExpression.escapedTemplate(for: rule.replace))
        }
    }

    public func apply(_ context: inout PipelineContext) {
        for rule in prepared {
            let range = NSRange(context.text.startIndex..., in: context.text)
            context.text = rule.regex.stringByReplacingMatches(in: context.text, range: range, withTemplate: rule.template)
        }
    }
}
