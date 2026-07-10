import Foundation

public struct RewriteEvalVariant: Sendable, Equatable, Identifiable {
    public let id: String
    public let summary: String

    public init(id: String, summary: String) {
        self.id = id
        self.summary = summary
    }
}

// Each variant is one candidate prompt feature toggled against baseline over the same cases. Screen
// terms deliberately ride the EXISTING term channels (validTerms + fuzzy candidates, mirroring
// RewriteRequestBuilder with the screen harvest as the dictionary) — the eval measures whether that
// channel works before any AX harvest is built.
public enum RewriteEvalVariants {
    public static let all: [RewriteEvalVariant] = [
        .init(id: "baseline", summary: "Today's shipped prompt: no screen terms, no experimental rules."),
        .init(id: "screen-terms", summary: "Case screen terms fed through the validTerms + fuzzy channels."),
        .init(id: "re-anchor", summary: "Output-only reminder appended as the system prompt's last line."),
        .init(id: "screen-terms-re-anchor", summary: "Screen terms plus the trailing reminder — the reminder's value shows only when term lists lengthen the system prompt."),
        .init(id: "field-hint", summary: "Single-line / plain-text destination-field rules."),
        .init(id: "locale", summary: "Language rule carries the locale spelling variant."),
        .init(id: "user-name", summary: "The user's name hinted as a valid term."),
        .init(id: "temp-0", summary: "Baseline prompt at temperature 0."),
    ]

    public static func build(
        _ c: RewriteEvalCase, variant: String
    ) -> (inputs: PromptInputs, options: PromptAssembler.Options)? {
        guard all.contains(where: { $0.id == variant }) else { return nil }
        var validTerms: [String] = []
        var fuzzy: [FuzzyCorrector.Candidate] = []
        var options = PromptAssembler.Options.baseline
        switch variant {
        case "screen-terms", "screen-terms-re-anchor":
            let lowerTranscript = c.transcript.lowercased()
            validTerms = c.screenTerms.filter { lowerTranscript.contains($0.lowercased()) }
            fuzzy = Array(FuzzyCorrector.candidates(
                c.transcript, prepared: FuzzyCorrector.prepare(c.screenTerms)).prefix(10))
            options.appendFinalReminder = variant == "screen-terms-re-anchor"
        case "user-name":
            if let name = c.userName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                validTerms = [name]
            }
        case "re-anchor":
            options.appendFinalReminder = true
        case "field-hint":
            options.fieldAffordanceRule = true
        case "locale":
            options.localeRule = true
        default:
            break
        }
        let inputs = PromptInputs(
            modePrompt: c.modePrompt, dictatedInstructions: "", content: c.transcript,
            tokens: c.tokens, validTerms: validTerms, fuzzyCandidates: fuzzy,
            styleRules: [], language: c.language,
            modeSystemInstructions: "",
            appName: c.appName, bundleId: nil, fieldRole: nil,
            selectedText: c.selectedText, precedingText: c.precedingText,
            locale: c.locale, fieldSingleLine: c.fieldSingleLine, fieldPlainText: c.fieldPlainText)
        return (inputs, options)
    }

    public static func temperatureOverride(variant: String) -> Double? {
        variant == "temp-0" ? 0 : nil
    }
}
