import Foundation
import Testing
@testable import KeyScribeKit

struct SpokenResultTests {
    @Test func nothingIsSpokenForAnEmptyReply() {
        #expect(SpokenResult.plan(answer: "  \n", configured: true) == .nothing)
        #expect(SpokenResult.plan(answer: "  \n", configured: false) == .nothing)
    }

    @Test func withoutAServiceAShortReplyIsSpokenAsItIsAndALongerOneSendsTheUserToTheConversation() {
        #expect(SpokenResult.plan(answer: "Done. `make test` passes.", configured: false) == .speak("Done. make test passes."))
        let long = Array(repeating: "word", count: SpokenResult.verbatimWordLimit + 1).joined(separator: " ")
        #expect(SpokenResult.plan(answer: long, configured: false) == .speak("Replied. Open the conversation for the result."))
    }

    @Test(arguments: [
        ("error", "Ended with an error."),
        ("refusal", "Couldn\u{2019}t complete the request."),
        ("unknown", "Replied. Open the conversation for the result."),
        ("max_turns", "Replied. Open the conversation for the result."),
    ])
    func aTurnThatEndedWithoutAReplySaysHowItEnded(reason: String, body: String) {
        #expect(SpokenResult.ending(reason) == body)
    }

    @Test(arguments: ["answer", "complete", "aborted"])
    func aReplyOrAnInterruptionHasNoEndingNotice(reason: String) {
        #expect(SpokenResult.ending(reason) == nil)
    }

    @Test func aShortReplyIsSpokenAsItIsAndALongerOneIsSummarized() {
        #expect(SpokenResult.plan(answer: "Done. The tests pass.", configured: true) == .speak("Done. The tests pass."))
        let long = Array(repeating: "word", count: SpokenResult.verbatimWordLimit + 1).joined(separator: " ")
        #expect(SpokenResult.plan(answer: long, configured: true) == .summarize(long))
        let justShort = Array(repeating: "word", count: SpokenResult.verbatimWordLimit).joined(separator: " ")
        #expect(SpokenResult.plan(answer: justShort, configured: true) == .speak(justShort))
    }

    @Test func theSpokenFormDropsMarkupAndNamesCodeBlocks() {
        let reply = """
        ## Result
        I **fixed** the `parse()` bug and added a test. See [the diff](https://example.com/d/1) or https://example.com/x.
        - one
        - two

        ```swift
        let x = 1
        ```
        | a | b |
        """
        #expect(SpokenResult.spokenForm(reply) == "Result I fixed the parse() bug and added a test. See the diff or a link. one two code block")
    }

    @Test func aReplyThatIsMostlyCodeIsSummarizedRatherThanReadAsAFewWords() {
        let code = (1...60).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        let reply = "Here is the change:\n```swift\n\(code)\n```"
        #expect(SpokenResult.plan(answer: reply, configured: true) == .summarize(reply))
    }

    @Test func aShortReplyNeverSpeaksASecretTheRedactionRecognizes() {
        #expect(SpokenResult.plan(answer: "The key is sk-abcdefghijklmnopqrstuvwxyz1234 now.", configured: true) == .speak("The key is a hidden value now."))
    }

    @Test func aReplyThatIsOnlyATableIsSummarizedNotDropped() {
        let table = "| Test | Result |\n|---|---|\n| parser | failed |\n| lexer | passed |"
        #expect(SpokenResult.plan(answer: table, configured: true) == .summarize(table))
    }

    @Test func aShortReplyWithCodeIsSpokenInItsSpokenForm() {
        #expect(SpokenResult.plan(answer: "Run `make test` now.", configured: true) == .speak("Run make test now."))
    }

    @Test func boundingKeepsTheOpeningAndTheWholeEnding() {
        let text = String(repeating: "a", count: 100) + String(repeating: "b", count: 100) + String(repeating: "c", count: 100)
        let bounded = SpokenResult.bounded(text, limit: 60)
        #expect(bounded.hasPrefix(String(repeating: "a", count: 20)))
        #expect(bounded.hasSuffix(String(repeating: "c", count: 35)))
        #expect(bounded.contains("[…]"))
        #expect(bounded.count <= 60)
        #expect(SpokenResult.bounded("short", limit: 60) == "short")
    }

    @Test func theRequestRedactsTheReplyAndHiddenValuesAreNeverSpoken() {
        let tokenizer = Tokenizer()
        let request = SpokenResult.request(
            answer: "Set the key to sk-abcdefghijklmnopqrstuvwxyz1234 and rerun.", prompt: "Summarize.", tokenizer: tokenizer)
        #expect(request.system.hasPrefix("Summarize."))
        #expect(request.system.contains("⟦SN:"))
        #expect(!request.user.contains("sk-abcdef"))
        #expect(request.user.contains("⟦SN:REDACT:1⟧"))
        let spoken = SpokenResult.spoken(summary: "It set the key to ⟦SN:REDACT:1⟧ and reran.")
        #expect(spoken == "It set the key to a hidden value and reran.")
        #expect(!spoken.contains("sk-abcdef"))
    }

    @Test func aPromptIsDescribedFromItsTitleAndToolWithSecretsRedacted() {
        let tokenizer = Tokenizer()
        let prompt = AgentPrompt(
            kind: "select", title: "Allow?", tool: "bash", detail: #"{"command":"curl -H 'Authorization: Bearer abcdefghijklmnop1234'"}"#,
            said: "Fetching the release notes.")
        let request = SpokenResult.waitingRequest(prompt, tokenizer: tokenizer)
        #expect(request?.system.hasPrefix(SpokenResult.waitingPrompt) == true)
        #expect(request?.system.contains("⟦SN:") == true)
        #expect(request?.user.contains("Allow?") == true)
        #expect(request?.user.contains("bash") == true)
        #expect(request?.user.contains("Kind: select") == true)
        #expect(request?.user.contains("Fetching the release notes.") == true)
        #expect(request?.user.contains("abcdefghijklmnop1234") == false)
        #expect(SpokenResult.waitingRequest(AgentPrompt(title: "Which database?"), tokenizer: Tokenizer())?.system == SpokenResult.waitingPrompt)
        #expect(SpokenResult.waitingRequest(AgentPrompt(), tokenizer: Tokenizer()) == nil)
        #expect(SpokenResult.waitingRequest(AgentPrompt(title: "  "), tokenizer: Tokenizer()) == nil)
        #expect(SpokenResult.waitingRequest(AgentPrompt(kind: "custom"), tokenizer: Tokenizer()) == nil)
        #expect(SpokenResult.waitingPrompt.contains("unrelated"))
    }

    @Test func aPlainReplyNeedsNoTokenNoteAndABoundedRequestNeverExceedsTheInputLimit() {
        let tokenizer = Tokenizer()
        let request = SpokenResult.request(answer: "All green.", prompt: "Summarize.", tokenizer: tokenizer)
        #expect(request.system == "Summarize.")
        let huge = String(repeating: "x", count: SpokenResult.inputCharacterLimit * 2)
        #expect(SpokenResult.request(answer: huge, prompt: "p", tokenizer: Tokenizer()).user.count <= SpokenResult.inputCharacterLimit)
    }

    @Test func theDefaultPromptAsksForAFewSpokenSentencesAndIsUsedUntilChanged() {
        var settings = SpokenResultSettings()
        #expect(!settings.isOn)
        #expect(settings.effectivePrompt == SpokenResultSettings.defaultPrompt)
        #expect(SpokenResultSettings.defaultPrompt.contains("sentences"))
        #expect(SpokenResultSettings.defaultPrompt.contains("about 25 words"))
        #expect(SpokenResultSettings.defaultPrompt.contains("Leave out everything else"))
        settings.enabled = true
        settings.connection = "omlx"
        settings.prompt = "Be brief."
        #expect(settings.isOn)
        #expect(settings.effectivePrompt == "Be brief.")
    }
}

struct SpokenResultSettingsDecodeTests {
    @Test func spokenResultSettingsAreReadFromTheirOwnTableAndDefaultWhenAbsent() throws {
        let absent = try SettingsStore.decode(from: "schema_version = 1")
        #expect(absent.codingAgents.spokenResult == SpokenResultSettings())
        let present = try SettingsStore.decode(from: """
        schema_version = 1

        [coding_agents.spoken_result]
        connection = "omlx"
        prompt = "Two sentences."
        voice = "com.apple.voice.compact.en-US.Samantha"
        """)
        #expect(present.codingAgents.spokenResult == SpokenResultSettings(connection: "omlx", prompt: "Two sentences.", voice: "com.apple.voice.compact.en-US.Samantha"))
    }
}

struct SpokenResultEnablementTests {
    @Test func textOnlyIsSavedBesideTheChosenVoice() throws {
        var settings = Settings.defaults
        settings.codingAgents.spokenResult = SpokenResultSettings(enabled: true, voice: "bf_emma", textOnly: true)
        let reread = try SettingsStore.decode(from: SettingsStore.encode(settings)).codingAgents.spokenResult
        #expect(reread.textOnly && reread.voice == "bf_emma" && reread.enabled)
    }

    @Test func readingAloudIsItsOwnSwitchAndNeedsAServiceToSpeak() {
        let off = SpokenResultSettings(enabled: false, connection: "omlx", prompt: "Be brief.", voice: "bf_emma")
        #expect(!off.isOn)
        #expect(off.connection == "omlx" && off.prompt == "Be brief." && off.voice == "bf_emma")
        let noService = SpokenResultSettings(enabled: true)
        #expect(noService.enabled && !noService.isOn)
        #expect(SpokenResultSettings(enabled: true, connection: "omlx").isOn)
    }

    @Test func updatesStayOffUntilTurnedOnEvenWithAServiceSaved() throws {
        let saved = try SettingsStore.decode(from: """
        schema_version = 1

        [coding_agents.spoken_result]
        connection = "omlx"
        """)
        #expect(!saved.codingAgents.spokenResult.enabled)
        #expect(!SpokenResultSettings(connection: "omlx").enabled)
    }

    @Test func aResultStartsWithItsConversationAndAFailedSummarySaysSo() {
        #expect(SpokenResult.prefaced("Done.", name: "keyscribe blue") == "keyscribe blue: Done.")
        #expect(SpokenResult.prefaced("Done.", name: "") == "Done.")
    }

    @Test func aConversationNeedingAttentionIsSpokenInTheSessionListsOwnWords() {
        #expect(SpokenResult.notice(.approval) == "Waiting for approval.")
        #expect(SpokenResult.notice(.question) == "Waiting for an answer.")
        #expect(SpokenResult.notice(.disconnected) == "Disconnected before it finished.")
        #expect(SpokenResult.notice(.waiting(AgentPrompt(title: "Allow?"))) == "Waiting for you.")
    }

    @Test func unavailableSummariesWaitingTogetherAreNamedInOneNotice() {
        func notice(_ names: [String]) -> String {
            let merged = SpokenResult.unavailable(names: names)
            return SpokenResult.prefaced(merged.body, name: merged.name)
        }
        #expect(notice(["keyscribe blue"]) == "keyscribe blue: No summary of the long reply. Open the conversation for the result.")
        #expect(notice([""]) == "No summary of the long reply. Open the conversation for the result.")
        #expect(notice(["api", "docs"]) == "api and docs: No summaries of the long replies. Open the conversations for the results.")
        #expect(notice(["api", "docs", "web"]) == "api, docs and web: No summaries of the long replies. Open the conversations for the results.")
        #expect(notice(["", ""]) == "No summaries of the long replies. Open the conversations for the results.")
        #expect(notice(["api", ""]) == "api: No summary of the long reply. Open the conversation for the result.")
        #expect(notice(["api", "docs", "api"]) == "api and docs: No summaries of the long replies. Open the conversations for the results.")
        #expect(notice(["api", "api"]) == "api: No summary of the long reply. Open the conversation for the result.")
    }
}

struct SpokenSummaryLengthTests {
    private func words(_ count: Int, _ word: String = "word") -> String {
        Array(repeating: word, count: count).joined(separator: " ")
    }

    @Test func aSummaryOfAnyReasonableLengthIsReadAsTheModelWroteIt() {
        let summary = words(SpokenResult.runawayWordLimit)
        #expect(SpokenResult.held(summary) == .init(text: summary, shortened: false))
        #expect(SpokenResult.held("The suite passed.") == .init(text: "The suite passed.", shortened: false))
    }

    @Test func aRunawaySummaryIsCutAtTheLastSentenceThatFits() {
        let opening = "The suite passed. " + words(SpokenResult.runawayWordLimit - 6) + " and one more."
        let runaway = opening + " " + words(40, "extra")
        let held = SpokenResult.held(runaway)
        #expect(held.shortened)
        #expect(held.text == opening)
        #expect(held.text.split(separator: " ").count <= SpokenResult.runawayWordLimit)
    }

    @Test func aRunawaySummaryWithNoSentenceEndIsCutAtTheLimitAndMarked() {
        let held = SpokenResult.held(words(SpokenResult.runawayWordLimit + 50))
        #expect(held.shortened)
        #expect(held.text == words(SpokenResult.runawayWordLimit) + "…")
    }

    @Test func aRunawaySummaryWhoseOnlySentenceEndIsVeryEarlyKeepsTheWordsThatFit() {
        let held = SpokenResult.held("Done. " + words(SpokenResult.runawayWordLimit + 50))
        #expect(held.shortened)
        #expect(held.text == "Done. " + words(SpokenResult.runawayWordLimit - 1) + "…")
    }
}
