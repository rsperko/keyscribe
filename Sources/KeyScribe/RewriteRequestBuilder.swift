import Foundation
import KeyScribeKit

// Assembles everything the LLM rewrite needs from a dictation's frozen state: the mode prompt +
// shared fragments, the dictionary "valid term" hints, the opted-in context channels (app identity,
// preceding text, visible window text — fitted to the token budget), and the sized connection. This
// is the cohesive, change-prone half of the old rewriteTokenized; pulling it out of DictationController
// keeps the controller to orchestration (HUD, state machine, restore, history) and isolates prompt
// construction. @MainActor because the context probes are (ContextProbe is main-actor isolated).
@MainActor
struct RewriteRequestBuilder {
    let mode: Mode
    let content: String
    let instruction: String
    let issuedTokens: [String]
    let capturedBundleId: String?
    let plan: ResolvedConfig
    let connection: Connection
    let visibleTextCap: Int
    let contextBudgetChars: Int

    struct Assembled {
        let sized: Connection
        let inputs: PromptInputs
        let promptForHistory: String
        let contextCategories: [String]
    }

    func build() async -> Assembled {
        // Give the model output room at least as large as the input (prompt_design.md budget).
        var sized = connection
        sized.params.maxTokens = ContextBudget.maxTokens(
            forSelectionChars: content.count, floor: connection.params.maxTokens)

        // Mode prompt + shared fragments (appended in order).
        let modePrompt = ([mode.aiRewrite?.prompt ?? ""] + plan.fragmentBodies(ids: mode.aiRewrite?.fragments ?? []))
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        // Dictionary terms present in the content → hinted as valid/not-misspelled (design.md §4.2).
        // Lowercase the content once rather than re-folding it per term inside a case-insensitive scan.
        let lowerContent = content.lowercased()
        let validTerms = plan.mergedDictionary(for: mode)
            .filter { lowerContent.contains($0.lowercased()) }

        // Context opt-in (mode.effectiveContext — privacy mode forces it all off). App identity and
        // visible-window text are the only context channels; the browser URL is a local routing key
        // only (design.md §4.3/§4.4) and never goes to the LLM.
        let ctx = mode.effectiveContext
        let bundleId = ctx.app ? capturedBundleId : nil
        let appName = bundleId.map { ContextProbe.appName(forBundleId: $0) ?? $0 }
        var contextCategories: [String] = []
        if ctx.app { contextCategories.append("app") }
        if ctx.precedingText { contextCategories.append("preceding text") }
        if ctx.visibleText { contextCategories.append("visible text") }

        // Both context probes are independent AX walks that run off the main actor; start them together
        // so a mode opting into both pays the longer wait, not the sum (each is individually bounded).
        let visibleBundleId = ctx.visibleText ? capturedBundleId : nil
        async let precedingProbe: String? = ctx.precedingText ? await ContextProbe.precedingText() : nil
        async let visibleProbe: String? = await {
            guard let visibleBundleId else { return nil }
            return await ContextProbe.visibleText(forBundleId: visibleBundleId, maxChars: visibleTextCap * 2)
        }()

        let precedingText = await precedingProbe
        if ctx.precedingText {
            Log.context.notice("preceding-text: \(precedingText?.count ?? 0, privacy: .public) chars")
        }

        var visibleWindowText: String?
        if ctx.visibleText {
            let captured = await visibleProbe
            let mandatoryChars = modePrompt.count + instruction.count + content.count
            switch ContextBudget.fit(mandatoryChars: mandatoryChars, visibleText: captured,
                                     budgetChars: contextBudgetChars, visibleCap: visibleTextCap) {
            case .ok(let fit):
                visibleWindowText = fit.visibleText
                Log.context.notice("visible-text: \(String(describing: fit.visibleDisposition), privacy: .public), \(fit.visibleText?.count ?? 0, privacy: .public) chars")
            case .refuse:
                Log.context.notice("visible-text dropped: mandatory content over budget")
            }
        }

        let inputs = PromptInputs(
            modePrompt: modePrompt, dictatedInstructions: instruction, content: content,
            tokens: issuedTokens, validTerms: validTerms, language: "English",
            modeSystemInstructions: "",
            appName: appName, bundleId: bundleId, fieldRole: nil,
            visibleWindowText: visibleWindowText, selectedText: nil, precedingText: precedingText)

        // The exact prompt stored in history (design.md §4.7) — tokens, not their originals.
        let assembled = PromptAssembler.assemble(inputs)
        let promptForHistory = "[system]\n\(assembled.system)\n\n[user]\n\(assembled.user)"

        return Assembled(
            sized: sized, inputs: inputs, promptForHistory: promptForHistory,
            contextCategories: contextCategories)
    }
}
