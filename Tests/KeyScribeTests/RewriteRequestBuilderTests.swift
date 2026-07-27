import Testing
import Foundation
@testable import KeyScribe
@testable import KeyScribeKit

struct RewriteRequestBuilderTests {
    private func pinnedDate() -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 10; comps.hour = 9; comps.minute = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        return cal.date(from: comps)!
    }

    // Localized formats use narrow/no-break spaces (U+202F before AM/PM) that don't compare against ASCII.
    private func asciiSpaces(_ s: String) -> String {
        String(s.map { $0.isWhitespace ? " " : $0 })
    }

    @Test func formattedDateTimeUsesLocaleAndTimeZone() {
        let formatted = RewriteRequestBuilder.formattedDateTime(
            pinnedDate(), locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/Chicago")!)
        #expect(asciiSpaces(formatted) == "Friday, July 10, 2026 at 9:00 AM (America/Chicago)")
    }

    @Test func formattedDateTimeHonorsA24HourLocale() {
        let formatted = RewriteRequestBuilder.formattedDateTime(
            pinnedDate(), locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "America/Chicago")!)
        #expect(formatted.contains("09:00"))
        #expect(!formatted.contains("AM"))
    }

    // FuzzyStage has already snapped every window candidates() could find, so this hint is provably dead
    // (and unwanted on selections) — the builder must not pass it through.
    @MainActor
    @Test func buildDoesNotHintFuzzyCandidates() async {
        var mode = Mode(id: "ai", name: "AI")
        mode.aiRewrite = .init(connection: "c", prompt: "Clean up.")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let plan = ResolvedConfig(
            modes: [mode], dictionary: DictionarySet(words: ["Postgres"]), replacements: ReplacementsSet(),
            connections: ConnectionSet(), fragments: [:])

        // Sanity: this transcript genuinely holds a near-miss the fuzzy corrector would surface.
        let content = "deployed postgress today"
        #expect(!FuzzyCorrector.candidates(
            content, prepared: FuzzyCorrector.prepare(["Postgres"])).isEmpty)

        let builder = RewriteRequestBuilder(
            mode: mode, content: content, instruction: "", issuedTokens: [],
            capturedBundleId: nil, capturedPid: nil, plan: plan, connection: conn)
        let assembled = await builder.build()
        #expect(assembled.inputs.fuzzyCandidates.isEmpty)
    }

    // History must not claim "preceding text" was shared when the probe returned nothing (KS-02).
    @MainActor
    @Test func contextCategoriesOmitsPrecedingTextWhenProbeReturnsNil() async {
        var mode = Mode(id: "ai", name: "AI")
        mode.aiRewrite = .init(connection: "c", prompt: "Clean up.", context: .init(precedingText: true))
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let plan = ResolvedConfig(
            modes: [mode], dictionary: DictionarySet(), replacements: ReplacementsSet(),
            connections: ConnectionSet(), fragments: [:])

        var absent = RewriteRequestBuilder(
            mode: mode, content: "hi", instruction: "", issuedTokens: [],
            capturedBundleId: nil, capturedPid: 7, plan: plan, connection: conn)
        absent.precedingTextProbe = { _, _ in nil }
        #expect(await absent.build().contextCategories == [])

        var present = RewriteRequestBuilder(
            mode: mode, content: "hi", instruction: "", issuedTokens: [],
            capturedBundleId: nil, capturedPid: 7, plan: plan, connection: conn)
        present.precedingTextProbe = { _, _ in "CTX" }
        #expect(await present.build().contextCategories == ["preceding text"])
    }

    // Field facts derive from the captured AX role and render as system rules (graduated 2026-07).
    @MainActor
    @Test func buildDerivesFieldFactsFromTheCapturedRole() async {
        var mode = Mode(id: "ai", name: "AI")
        mode.aiRewrite = .init(connection: "c", prompt: "Clean up.")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let plan = ResolvedConfig(
            modes: [mode], dictionary: DictionarySet(), replacements: ReplacementsSet(),
            connections: ConnectionSet(), fragments: [:])

        var builder = RewriteRequestBuilder(
            mode: mode, content: "hi", instruction: "", issuedTokens: [],
            capturedBundleId: nil, capturedPid: nil, plan: plan, connection: conn)
        builder.capturedFieldRole = "AXTextField"
        let assembled = await builder.build()
        #expect(assembled.inputs.fieldSingleLine == true)
        #expect(assembled.inputs.fieldPlainText == nil)
        #expect(assembled.prompt.system.contains("single-line field"))

        builder.capturedFieldRole = "AXTextArea"
        #expect(await builder.build().inputs.fieldSingleLine == false)

        builder.capturedFieldRole = nil
        let bare = await builder.build()
        #expect(bare.inputs.fieldSingleLine == nil)
        #expect(!bare.prompt.system.contains("single-line field"))
    }

    // REJECTED FEATURE, pinned: automatically harvested screen terms must NOT reach the prompt's term
    // channels. Measured net-positive but not regression-free on either eval model, and the failure is
    // structural (a 2-token join like "parse config"→parseConfig is indistinguishable from "use
    // state"→useState in ordinary prose). The Dictionary is the consented form of this. If this test
    // starts failing, the channel has been reintroduced — re-read evals/rewrite/README.md first.
    @MainActor
    @Test func harvestedScreenTermsNeverReachThePromptTermChannels() async {
        var mode = Mode(id: "ai", name: "AI")
        mode.aiRewrite = .init(
            connection: "c", prompt: "Clean up.", context: .init(precedingText: true))
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let plan = ResolvedConfig(
            modes: [mode], dictionary: DictionarySet(), replacements: ReplacementsSet(),
            connections: ConnectionSet(), fragments: [:])

        var builder = RewriteRequestBuilder(
            mode: mode, content: "call useState then install postgresqll now", instruction: "",
            issuedTokens: [], capturedBundleId: nil, capturedPid: 42, plan: plan, connection: conn)
        builder.precedingTextProbe = { _, _ in
            "const [count, setCount] = useState(0)\nconnect to PostgreSQL for storage"
        }
        let assembled = await builder.build()
        #expect(assembled.inputs.validTerms.isEmpty)
        #expect(assembled.inputs.fuzzyCandidates.isEmpty)
        // The context channel itself is unaffected — only the term hints were removed.
        #expect(assembled.inputs.precedingText?.contains("useState") == true)
    }

    // The user's curated dictionary still feeds validTerms — that path is untouched by the removal.
    @MainActor
    @Test func curatedDictionaryTermsStillReachValidTerms() async {
        var mode = Mode(id: "ai", name: "AI")
        mode.aiRewrite = .init(connection: "c", prompt: "Clean up.")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let plan = ResolvedConfig(
            modes: [mode], dictionary: DictionarySet(words: ["useState"]), replacements: ReplacementsSet(),
            connections: ConnectionSet(), fragments: [:])

        var builder = RewriteRequestBuilder(
            mode: mode, content: "call useState now", instruction: "", issuedTokens: [],
            capturedBundleId: nil, capturedPid: nil, plan: plan, connection: conn)
        builder.capturedFieldRole = nil
        let assembled = await builder.build()
        #expect(assembled.inputs.validTerms == ["useState"])
    }

    // A plain capitalized word on screen is not identifier-shaped, so the extractor drops it and no
    // channel ever sees it — the Dictionary remains the route for that class of term.
    @MainActor
    @Test func unharvestableScreenWordsNeverReachTheTermChannels() async {
        var mode = Mode(id: "ai", name: "AI")
        mode.aiRewrite = .init(
            connection: "c", prompt: "Clean up.", context: .init(precedingText: true))
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let plan = ResolvedConfig(
            modes: [mode], dictionary: DictionarySet(), replacements: ReplacementsSet(),
            connections: ConnectionSet(), fragments: [:])

        var builder = RewriteRequestBuilder(
            mode: mode, content: "the postgress database is slow", instruction: "", issuedTokens: [],
            capturedBundleId: nil, capturedPid: 42, plan: plan, connection: conn)
        builder.precedingTextProbe = { _, _ in "The primary datastore is Postgres in the cluster." }
        let assembled = await builder.build()
        #expect(assembled.inputs.validTerms.isEmpty)
        #expect(assembled.inputs.fuzzyCandidates.isEmpty)
    }

    @MainActor
    @Test func privacySuppressesFieldFacts() async {
        var mode = Mode(id: "ai", name: "AI")
        mode.aiRewrite = .init(connection: "c", prompt: "Clean up.")
        mode.commands.privacy = true
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let plan = ResolvedConfig(
            modes: [mode], dictionary: DictionarySet(), replacements: ReplacementsSet(),
            connections: ConnectionSet(), fragments: [:])

        var builder = RewriteRequestBuilder(
            mode: mode, content: "hi", instruction: "", issuedTokens: [],
            capturedBundleId: nil, capturedPid: nil, plan: plan, connection: conn)
        builder.capturedFieldRole = "AXTextField"
        let assembled = await builder.build()
        #expect(assembled.inputs.fieldSingleLine == nil)
        #expect(assembled.inputs.fieldPlainText == nil)
    }

    @MainActor
    @Test func buildWiresPinnedDateTimeAndLocaleIntoPrompt() async {
        var mode = Mode(id: "ai", name: "AI")
        mode.aiRewrite = .init(connection: "c", prompt: "Clean up.")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let plan = ResolvedConfig(
            modes: [mode], dictionary: DictionarySet(), replacements: ReplacementsSet(),
            connections: ConnectionSet(), fragments: [:])

        var builder = RewriteRequestBuilder(
            mode: mode, content: "meeting next Friday", instruction: "", issuedTokens: [],
            capturedBundleId: nil, capturedPid: nil, plan: plan, connection: conn)
        builder.now = { self.pinnedDate() }
        builder.locale = Locale(identifier: "en_US")
        builder.timeZone = TimeZone(identifier: "America/Chicago")!

        let assembled = await builder.build()
        #expect(asciiSpaces(assembled.inputs.currentDateTime ?? "") == "Friday, July 10, 2026 at 9:00 AM (America/Chicago)")
        #expect(assembled.inputs.locale == "en-US")
        #expect(asciiSpaces(assembled.prompt.system).contains(
            "- Current date and time: Friday, July 10, 2026 at 9:00 AM (America/Chicago)."))
        #expect(assembled.prompt.system.contains("- Write in English (en-US spelling conventions)."))
    }
}
