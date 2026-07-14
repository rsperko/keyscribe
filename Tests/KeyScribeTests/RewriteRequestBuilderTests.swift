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
            capturedBundleId: nil, plan: plan, connection: conn)
        let assembled = await builder.build()
        #expect(assembled.inputs.fuzzyCandidates.isEmpty)
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
            capturedBundleId: nil, plan: plan, connection: conn)
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
