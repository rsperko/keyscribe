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

    public init(rules: [ReplacementRule]) { self.rules = rules }

    public func apply(_ context: inout PipelineContext) {
        for rule in rules { context.text = applyRule(rule, to: context.text) }
    }

    private func applyRule(_ rule: ReplacementRule, to text: String) -> String {
        if rule.isRegex {
            guard ReplacementSafety.isSafe(rule.heard), let re = RegexCache.regex(rule.heard) else { return text }
            let range = NSRange(text.startIndex..., in: text)
            return re.stringByReplacingMatches(in: text, range: range, withTemplate: rule.replace)
        }
        guard !rule.heard.isEmpty else { return text }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: rule.heard))\\b"
        guard let re = RegexCache.regex(pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: rule.replace)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
