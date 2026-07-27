import Foundation

public struct RewriteEvalVariant: Sendable, Equatable, Identifiable {
    public let id: String
    public let summary: String

    public init(id: String, summary: String) {
        self.id = id
        self.summary = summary
    }
}

// Each variant is one candidate prompt feature toggled against baseline over the same cases. The
// screen-terms variants run the REAL production path, not an idealized one: terms are harvested from
// the case's precedingText — production's ONLY source, and one both arms receive identically — then
// pass through ScreenTermExtractor's classification (a term production would never harvest, like a
// plain capitalized surname, is dropped), the exact/single-token local stage snaps the transcript,
// and the prompt channels are built from the snapped content exactly as RewriteRequestBuilder does.
// Harvesting from an injected term list instead measured explicit hints against no screen context at
// all, crediting the channel with wins raw context may already deliver.
public enum RewriteEvalVariants {
    public static let all: [RewriteEvalVariant] = [
        .init(id: "baseline", summary: "Today's shipped prompt: no screen terms, no experimental rules."),
        .init(id: "screen-terms", summary: "Identifiers harvested from the case's preceding text, fed through the validTerms + fuzzy channels."),
        .init(id: "re-anchor", summary: "Output-only reminder appended as the system prompt's last line."),
        .init(id: "screen-terms-re-anchor", summary: "Harvested screen terms plus the trailing reminder — the reminder's value shows only when term lists lengthen the system prompt."),
        .init(id: "user-name", summary: "The user's name hinted as a valid term."),
        .init(id: "temp-0", summary: "Baseline prompt at temperature 0."),
    ]

    public static func build(
        _ c: RewriteEvalCase, variant: String
    ) -> (inputs: PromptInputs, options: PromptAssembler.Options)? {
        guard all.contains(where: { $0.id == variant }) else { return nil }
        var content = c.transcript
        var validTerms: [String] = []
        var fuzzy: [FuzzyCorrector.Candidate] = []
        var options = PromptAssembler.Options.baseline
        switch variant {
        case "screen-terms", "screen-terms-re-anchor":
            // Harvest from precedingText — the ONLY source production has. Injecting the case's
            // screenTerms directly measured explicit hints against no screen context at all, while
            // production always sends that same text as <context> to both arms; the variant then
            // credited the term channel with wins the raw context may already deliver.
            let harvested = ScreenTermExtractor.terms(in: c.precedingText ?? "", excluding: [])
            content = FuzzyCorrector.apply(
                c.transcript, prepared: FuzzyCorrector.prepare(harvested, matching: .exactNormalized))
            let lowerContent = content.lowercased()
            validTerms = harvested.filter { lowerContent.contains($0.lowercased()) }
            fuzzy = Array(FuzzyCorrector.candidates(
                content, prepared: FuzzyCorrector.prepare(harvested)).prefix(10))
            options.appendFinalReminder = variant == "screen-terms-re-anchor"
        case "user-name":
            if let name = c.userName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                validTerms = [name]
            }
        case "re-anchor":
            options.appendFinalReminder = true
        default:
            break
        }
        let inputs = PromptInputs(
            modePrompt: c.modePrompt, dictatedInstructions: "", content: content,
            tokens: c.tokens, validTerms: validTerms, fuzzyCandidates: fuzzy,
            styleRules: [], language: c.language,
            modeSystemInstructions: "",
            appName: c.appName, bundleId: nil, fieldRole: nil,
            selectedText: c.selectedText, precedingText: c.precedingText,
            locale: c.locale, fieldSingleLine: c.fieldSingleLine, fieldPlainText: c.fieldPlainText,
            currentDateTime: c.currentDateTime)
        return (inputs, options)
    }

    public static func temperatureOverride(variant: String) -> Double? {
        variant == "temp-0" ? 0 : nil
    }
}
