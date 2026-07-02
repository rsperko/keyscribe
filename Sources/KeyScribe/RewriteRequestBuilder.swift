import Foundation
import KeyScribeKit

// Assembles everything the LLM rewrite needs from a dictation's frozen state: the mode prompt +
// shared fragments, the dictionary "valid term" hints, the opted-in context channels (app identity,
// preceding text), and the sized connection. @MainActor because the context probes are main-actor isolated.
@MainActor
struct RewriteRequestBuilder {
    let mode: Mode
    let content: String
    let instruction: String
    let issuedTokens: [String]
    let capturedBundleId: String?
    let plan: ResolvedConfig
    let connection: Connection

    struct Assembled {
        let sized: Connection
        let inputs: PromptInputs
        let prompt: RewritePrompt
        let promptForHistory: String
        let contextCategories: [String]
    }

    func build() async -> Assembled {
        // Give the model output room at least as large as the input (prompt_design.md budget).
        var sized = connection
        sized.params.maxTokens = ContextBudget.maxTokens(
            forSelectionChars: content.count, floor: connection.params.maxTokens)

        // The mode prompt is the task; shared fragments are standing style rules layered on top. They
        // are passed separately (not flattened in) so PromptAssembler can label them and signal
        // precedence — see prompt_design.md.
        let modePrompt = mode.aiRewrite?.prompt ?? ""
        let styleRules = plan.fragmentBodies(ids: mode.aiRewrite?.fragments ?? [])

        // Dictionary terms present in the content → hinted as valid/not-misspelled (design.md §4.2).
        // Lowercase the content once rather than re-folding it per term inside a case-insensitive scan.
        let lowerContent = content.lowercased()
        let validTerms = plan.mergedDictionary(for: mode)
            .filter { lowerContent.contains($0.lowercased()) }

        // Context opt-in (mode.effectiveContext — privacy mode forces it all off). App identity is a
        // context channel; the browser URL is a local routing key only (design.md §4.3/§4.4) and never
        // goes to the LLM.
        let ctx = mode.effectiveContext
        let bundleId = ctx.app ? capturedBundleId : nil
        let appName = bundleId.map { ContextProbe.appName(forBundleId: $0) ?? $0 }
        var contextCategories: [String] = []
        if ctx.app { contextCategories.append("app") }
        if ctx.precedingText { contextCategories.append("preceding text") }

        let precedingBundleId = ctx.precedingText ? capturedBundleId : nil
        let precedingText: String? = await {
            guard let precedingBundleId else { return nil }
            return await ContextProbe.precedingText(forBundleId: precedingBundleId)
        }()
        if ctx.precedingText {
            Log.context.notice("preceding-text: \(precedingText?.count ?? 0, privacy: .public) chars")
        }

        let inputs = PromptInputs(
            modePrompt: modePrompt, dictatedInstructions: instruction, content: content,
            tokens: issuedTokens, validTerms: validTerms, styleRules: styleRules, language: "English",
            modeSystemInstructions: "",
            appName: appName, bundleId: bundleId, fieldRole: nil,
            selectedText: nil, precedingText: precedingText)

        // The exact prompt stored in history (design.md §4.7) — tokens, not their originals. Assembled
        // once here and handed to RewriteService so the same inputs are not assembled a second time.
        let assembled = PromptAssembler.assemble(inputs)
        let promptForHistory = "[system]\n\(assembled.system)\n\n[user]\n\(assembled.user)"

        return Assembled(
            sized: sized, inputs: inputs, prompt: assembled, promptForHistory: promptForHistory,
            contextCategories: contextCategories)
    }
}
