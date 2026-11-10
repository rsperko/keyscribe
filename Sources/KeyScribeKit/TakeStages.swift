import Foundation

public enum TakeStages {
    public static func text(liveEdits: Bool, rules: [ReplacementRule], numbers: Bool, dictionary: [String]) -> [any PipelineStage] {
        var stages: [any PipelineStage] = []
        if liveEdits { stages.append(LiveEditsStage()) }
        stages.append(ReplacementsStage(rules: rules))
        if numbers { stages.append(NumbersStage()) }
        if !dictionary.isEmpty { stages.append(FuzzyStage(terms: dictionary)) }
        return stages
    }

    public static func withoutDictionary(_ text: [any PipelineStage]) -> [any PipelineStage] {
        text.filter { !($0 is FuzzyStage) }
    }

    public static func dictation(
        text: [any PipelineStage], clipboard: (@Sendable () -> String?)?, redaction: Bool
    ) -> Pipeline {
        guard let clipboard else { return dictation(text: text, clip: nil, redaction: redaction) }
        return dictation(text: text, clip: { @Sendable in clipboard().map { ClipboardTokenizer.Clip(text: $0) } }, redaction: redaction)
    }

    public static func dictation(
        text: [any PipelineStage], clip: (@Sendable () -> ClipboardTokenizer.Clip?)?, redaction: Bool
    ) -> Pipeline {
        var stages = text
        if text.contains(where: { $0 is LiveEditsStage }) {
            stages.append(TokenizingStage.verbatim())
            if let clip { stages.append(TokenizingStage.clipboard(clip: clip)) }
        }
        if redaction { stages.append(TokenizingStage.redaction()) }
        return Pipeline(stages)
    }

    public static func selection(liveEdits: Bool, redaction: Tokenizer?) -> Pipeline {
        var stages: [any PipelineStage] = []
        if liveEdits { stages.append(TokenizingStage.verbatim()) }
        if let redaction { stages.append(TokenizingStage.redaction(tokenizer: redaction)) }
        return Pipeline(stages)
    }
}
