import Foundation
import KeyScribeKit

// Assembles everything the LLM rewrite needs from a dictation's frozen state: mode prompt + shared
// fragments, dictionary valid-term hints, opted-in context channels, and the sized connection.
// @MainActor because the context probes are main-actor isolated.
@MainActor
struct RewriteRequestBuilder {
    let mode: Mode
    let content: String
    let instruction: String
    let issuedTokens: [String]
    let capturedBundleId: String?
    // The captured process' pid + focused window — the preceding-text probe reads only this exact process
    // and window, so context can't be sourced from another same-bundle instance or a document the user
    // switched to during recording (KS-02).
    let capturedPid: pid_t?
    var capturedWindowId: String? = nil
    // AX role of the captured focused element — source for the content-free field-affordance rules.
    var capturedFieldRole: String? = nil
    let plan: ResolvedConfig
    let connection: Connection
    var precedingTextTask: Task<String?, Never>? = nil
    var precedingTextProbe: @MainActor (pid_t, String?) async -> String? = { await ContextProbe.precedingText(pid: $0, windowId: $1) }
    // Clock/locale seam so tests can pin the date/time line and spelling variant.
    var now: () -> Date = { Date() }
    var locale: Locale = .current
    var timeZone: TimeZone = .current

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

        // Mode prompt = the task; shared fragments = style rules layered on top, passed separately (not
        // flattened) so PromptAssembler can label them and signal precedence (prompt_design.md).
        let modePrompt = mode.aiRewrite?.prompt ?? ""
        let styleRules = plan.fragmentBodies(ids: mode.aiRewrite?.fragments ?? [])

        // Dictionary terms present in the content → hinted as valid/not-misspelled (design.md §4.2).
        // ONLY the user's curated dictionary feeds this channel. Automatically harvested screen terms
        // were tried here and REJECTED — see the block below the context resolution.
        let dictionary = plan.mergedDictionary(for: mode)
        let lowerContent = content.lowercased()
        let validTerms = dictionary.filter { lowerContent.contains($0.lowercased()) }

        // Context opt-in (mode.effectiveContext — privacy mode forces it all off). App identity is a context
        // channel; the browser URL is a local routing key only, never sent to the LLM (design.md §4.3/§4.4).
        let ctx = mode.effectiveContext
        let bundleId = ctx.app ? capturedBundleId : nil
        let appName = bundleId.map { ContextProbe.appName(forBundleId: $0) ?? $0 }

        let precedingPid = ctx.precedingText ? capturedPid : nil
        let precedingText: String? = await {
            guard let precedingPid else { return nil }
            if let precedingTextTask { return await precedingTextTask.value }
            return await precedingTextProbe(precedingPid, capturedWindowId)
        }()
        if ctx.precedingText {
            Log.context.notice("preceding-text: \(precedingText?.count ?? 0, privacy: .public) chars")
        }

        // REJECTED: automatically harvesting screen terms into the term channels.
        // Measured on the paired corpus at --repeat 3, it was net-positive but NOT regression-free, and
        // the failure is structural rather than a wording bug. FuzzyCorrector.candidates emits 2-token
        // exact-normalized joins that are indistinguishable from each other:
        //   "parse config" → parseConfig  in "rename the parse config function"   — the win
        //   "use state"    → useState     in "we should use state funds"          — prose corruption
        // Only the model can separate them, so the rule is hedged; gemini then adjudicates toward
        // applying (+4 recalls, but it writes "useState funds") while qwen adjudicates toward preserving
        // (prose intact, but it leaves "parse config"). Making the rule directive wins one and loses the
        // other on EVERY model. The collision class is structural, not exotic — camelCase identifiers are
        // ordinary words concatenated (userName/"user name", fileName/"file name", dataSource/"data
        // source") — and the harm is asymmetric: a missed identifier is invisible, corrupted prose is
        // visible, wrong, and inside the atomic insert. The Dictionary already expresses this intent
        // deliberately, which is the safe form of the same feature. Evidence kept as the `screen-terms`
        // eval variant plus the `code-identifiers` / `distractor-usestate-prose` regression cases;
        // full write-up in evals/rewrite/README.md.
        // Report a context channel only when it actually contributed content — history must not claim
        // "preceding text" was shared when the probe returned nothing (KS-02).
        var contextCategories: [String] = []
        if ctx.app { contextCategories.append("app") }
        if ctx.precedingText, precedingText != nil { contextCategories.append("preceding text") }

        let language = "English"
        let localeIdentifier = language == "English" ? locale.identifier(.bcp47) : nil

        // Content-free affordances, not a context channel — they render as system RULES, and the raw
        // role string stays out of <context>. Suppressed under privacy to keep its story one
        // sentence: only the redacted transcript leaves.
        let fieldFacts = mode.commands.privacy ? FieldFacts(singleLine: nil, plainText: nil)
            : FieldFacts.derive(role: capturedFieldRole)

        let inputs = PromptInputs(
            modePrompt: modePrompt, dictatedInstructions: instruction, content: content,
            tokens: issuedTokens, validTerms: validTerms, fuzzyCandidates: [],
            styleRules: styleRules, language: language,
            modeSystemInstructions: "",
            appName: appName, bundleId: bundleId, fieldRole: nil,
            selectedText: nil, precedingText: precedingText,
            locale: localeIdentifier, fieldSingleLine: fieldFacts.singleLine, fieldPlainText: fieldFacts.plainText,
            currentDateTime: Self.formattedDateTime(now(), locale: locale, timeZone: timeZone))

        // The exact prompt stored in history (design.md §4.7) — tokens, not their originals. Assembled once
        // and handed to RewriteService so the inputs aren't assembled twice.
        let assembled = PromptAssembler.assemble(inputs)
        let promptForHistory = "[system]\n\(assembled.system)\n\n[user]\n\(assembled.user)"

        return Assembled(
            sized: sized, inputs: inputs, prompt: assembled, promptForHistory: promptForHistory,
            contextCategories: contextCategories)
    }

    nonisolated static func formattedDateTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return "\(formatter.string(from: date)) (\(timeZone.identifier))"
    }
}
