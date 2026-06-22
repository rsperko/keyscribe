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

// Post-STT text stage. Literal matches are case-insensitive; regex rules use
// NSRegularExpression with template substitution ($1 for capture groups, \$ for a literal $).
// An invalid regex is skipped rather than aborting the dictation. Replacements run before any
// tokenization (design.md §4.2.1) and are not protected from a later LLM rewrite (design.md §4.2).
public struct ReplacementsStage: PipelineStage {
    public let position = StagePosition.postSTTText
    public let order = StageOrder.replacements
    public let rules: [ReplacementRule]

    public init(rules: [ReplacementRule]) { self.rules = rules }

    public func run(_ context: inout PipelineContext) {
        for rule in rules { context.text = apply(rule, to: context.text) }
    }

    private func apply(_ rule: ReplacementRule, to text: String) -> String {
        if rule.isRegex {
            guard ReplacementSafety.isSafe(rule.heard), let re = RegexCache.regex(rule.heard) else { return text }
            let range = NSRange(text.startIndex..., in: text)
            return re.stringByReplacingMatches(in: text, range: range, withTemplate: rule.replace)
        }
        guard !rule.heard.isEmpty else { return text }
        return text.replacingOccurrences(of: rule.heard, with: rule.replace, options: [.caseInsensitive])
    }
}
