import Testing
import Foundation
@testable import KeyScribe
@testable import KeyScribeKit

struct RewriteRequestBuilderTests {
    @Test func formattedDateTimeUsesLocaleAndTimeZone() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 10; comps.hour = 9; comps.minute = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let date = cal.date(from: comps)!

        let formatted = RewriteRequestBuilder.formattedDateTime(
            date, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/Chicago")!)
        #expect(formatted == "Friday, July 10, 2026, 9:00 AM (America/Chicago)")
    }

    @MainActor
    @Test func buildWiresPinnedDateTimeAndLocaleIntoPrompt() async {
        var mode = Mode(id: "ai", name: "AI")
        mode.aiRewrite = .init(connection: "c", prompt: "Clean up.")
        let conn = Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k")
        let plan = ResolvedConfig(
            modes: [mode], dictionary: DictionarySet(), replacements: ReplacementsSet(),
            connections: ConnectionSet(), fragments: [:])

        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 10; comps.hour = 9; comps.minute = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let date = cal.date(from: comps)!

        var builder = RewriteRequestBuilder(
            mode: mode, content: "meeting next Friday", instruction: "", issuedTokens: [],
            capturedBundleId: nil, plan: plan, connection: conn)
        builder.now = { date }
        builder.locale = Locale(identifier: "en_US")
        builder.timeZone = TimeZone(identifier: "America/Chicago")!

        let assembled = await builder.build()
        #expect(assembled.inputs.currentDateTime == "Friday, July 10, 2026, 9:00 AM (America/Chicago)")
        #expect(assembled.inputs.locale == "en-US")
        #expect(assembled.prompt.system.contains(
            "- Current date and time: Friday, July 10, 2026, 9:00 AM (America/Chicago)."))
        #expect(assembled.prompt.system.contains("- Write in English (en-US spelling conventions)."))
    }
}
