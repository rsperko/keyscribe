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
        #expect(SpokenResult.spokenForm(reply) == "Result. I fixed the parse() bug and added a test. See the diff or a link. one. two. code block")
    }

    @Test(arguments: [
        ("Extra\n\n`sleep 20` is still running.", "Extra. sleep 20 is still running."),
        ("Done!\n\nNext step", "Done! Next step"),
        ("Checked:\n\n- the parser\n- the lexer", "Checked: the parser. the lexer."),
        ("one line\nwrapped here", "one line wrapped here"),
        ("Extra\r\n\r\nmore", "Extra. more"),
        ("- still going…\n- done", "still going… done."),
    ])
    func aParagraphBreakOrAListItemIsReadAsTheEndOfASentence(reply: String, spoken: String) {
        #expect(SpokenResult.spokenForm(reply) == spoken)
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

    @Test func theCueNamesTheRequestOnlyWhenTheReplyCameRightAfterIt() {
        let asked = "Yes to all four."
        let mine = AgentPromptDigest.of(asked)
        #expect(SpokenResult.cause(after: AgentTurnInput(from: nil, prompt: mine), asked: asked) == .request(asked))
        #expect(SpokenResult.cause(after: AgentTurnInput(from: .other, prompt: mine), asked: asked) == .request(asked))
        #expect(SpokenResult.cause(after: AgentTurnInput(from: .agent, prompt: AgentPromptDigest.of("Found it.")), asked: asked)
            == .sender(.agent))
        #expect(SpokenResult.cause(after: AgentTurnInput(from: nil, prompt: AgentPromptDigest.of("typed later")), asked: asked) == nil)
        #expect(SpokenResult.cause(after: AgentTurnInput(from: nil, prompt: mine), asked: nil) == nil)
        #expect(SpokenResult.cause(after: nil, asked: asked) == nil)
        #expect(SpokenResult.cause(after: AgentTurnInput(from: .task, prompt: nil), asked: nil) == .sender(.task))
    }

    @Test func theCueNamesTheRequestWhenItIsTheLastMessageTheTurnTook() {
        let asked = "also reply with two"
        let first = AgentPromptDigest.of("reply with one")
        let mine = AgentPromptDigest.of(asked)
        #expect(SpokenResult.cause(after: AgentTurnInput(from: nil, prompt: first, accepted: [.init(digest: first, at: nil), .init(digest: mine, at: nil)]), asked: asked) == .request(asked))
        #expect(SpokenResult.cause(after: AgentTurnInput(from: nil, prompt: nil, accepted: [.init(digest: mine, at: nil), .init(digest: first, at: nil)]), asked: asked) == nil)
        #expect(SpokenResult.cause(after: AgentTurnInput(from: nil, prompt: mine, accepted: [.init(digest: first, at: nil)]), asked: asked) == nil)
        #expect(SpokenResult.cause(after: AgentTurnInput(from: nil, prompt: mine, accepted: []), asked: asked) == nil)
    }

    @Test func aSenderCueJoinsTheConversationNameWithoutAddingASentence() {
        #expect(SpokenResult.prefaced("Done.", name: "auth", cause: .sender(.agent)) == "auth, answering another agent: Done.")
        #expect(SpokenResult.prefaced("Done.", name: "", cause: .sender(.task)) == "After a background task: Done.")
        #expect(SpokenResult.prefaced("Done.", name: "auth", cause: .request("Fix it.")) == "auth: Done.")
        #expect(SpokenResult.prefaced("Done.", name: "auth", cause: nil) == "auth: Done.")
        for sender in AgentTurnInput.Sender.allCases {
            let cue = SpokenResult.prefaced("Done.", name: "auth", cause: .sender(sender))
            #expect(cue.split(separator: " ").count <= 6)
            #expect(cue.filter { ".!?".contains($0) }.count == 1)
        }
    }

    @Test func theSummarizerSeesTheRequestBeforeTheReplyBothRedacted() {
        let tokenizer = Tokenizer()
        let request = SpokenResult.request(
            answer: "Rotated sk-abcdefghijklmnopqrstuvwxyz1234 and the tests pass.", asked: "Rotate the key sk-zyxwvutsrqponmlkjihgfedcba9876 please",
            prompt: "Summarize.", tokenizer: tokenizer)
        #expect(request.user.hasPrefix("Request:\n"))
        #expect(request.user.contains("\n\nReply:\n"))
        #expect(!request.user.contains("sk-abcdef"))
        #expect(!request.user.contains("sk-zyxw"))
        #expect(request.system.contains("⟦SN:"))
        let long = String(repeating: "word ", count: 2_000)
        let bounded = SpokenResult.request(answer: "Done.", asked: long, prompt: "p", tokenizer: Tokenizer())
        #expect(bounded.user.count <= SpokenResult.askedCharacterLimit + 100)
        #expect(SpokenResult.request(answer: "All green.", asked: nil, prompt: "p", tokenizer: Tokenizer()).user == "All green.")
    }

    @Test func aChangedInstructionIsToldWhichPartIsTheRequestOnlyWhenOneIsSent() {
        let custom = SpokenResult.request(answer: "Done.", asked: "Fix it.", prompt: "Be brief.", tokenizer: Tokenizer()).system
        #expect(custom.hasPrefix("Be brief.\n\n"))
        #expect(custom.contains("Summarize the reply"))
        #expect(SpokenResult.request(answer: "Done.", asked: nil, prompt: "Be brief.", tokenizer: Tokenizer()).system == "Be brief.")
        let standard = SpokenResultSettings.defaultPrompt
        #expect(SpokenResult.request(answer: "Done.", asked: "Fix it.", prompt: standard, tokenizer: Tokenizer()).system == standard)
    }

    @Test func theDefaultPromptOpensWithTheRequestAndKeepsTheSameLength() {
        let prompt = SpokenResultSettings.defaultPrompt
        #expect(prompt.contains("about 25 words in all"))
        #expect(prompt.contains("under \"Request:\", open with two to five words naming"))
        #expect(prompt.contains("comes first"))
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
        #expect(absent.agents.spokenResult == SpokenResultSettings())
        let present = try SettingsStore.decode(from: """
        schema_version = 1

        [agents.spoken_result]
        connection = "omlx"
        prompt = "Two sentences."
        voice = "com.apple.voice.compact.en-US.Samantha"
        """)
        #expect(present.agents.spokenResult == SpokenResultSettings(connection: "omlx", prompt: "Two sentences.", voice: "com.apple.voice.compact.en-US.Samantha"))
    }
}

struct SpokenResultEnablementTests {
    @Test func textOnlyIsSavedBesideTheChosenVoice() throws {
        var settings = Settings.defaults
        settings.agents.spokenResult = SpokenResultSettings(enabled: true, voice: "bf_emma", textOnly: true)
        let reread = try SettingsStore.decode(from: SettingsStore.encode(settings)).agents.spokenResult
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

        [agents.spoken_result]
        connection = "omlx"
        """)
        #expect(!saved.agents.spokenResult.enabled)
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

    @Test func aPromptOfAKnownKindIsSpokenAsWhatItWaitsFor() {
        #expect(SpokenResult.notice(.waiting(AgentPrompt(kind: "confirm", detail: "git push"))) == "Waiting for approval.")
        for kind in ["select", "input", "editor"] {
            #expect(SpokenResult.notice(.waiting(AgentPrompt(kind: kind, title: "Which branch?"))) == "Waiting for an answer.")
        }
        #expect(SpokenResult.notice(.waiting(AgentPrompt(kind: "custom", title: "Sign in"))) == "Waiting for you.")
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

struct AgentHostSettingsTests {
    @Test func noHostIsOnUntilTheUserTurnsItOn() throws {
        #expect(try SettingsStore.decode(from: "schema_version = 1").agents.hosts == [])
        let saved = try SettingsStore.decode(from: """
        schema_version = 1

        [agents]
        hosts = ["bb", "other"]
        """)
        #expect(saved.agents.hosts == ["bb", "other"])
    }

    @Test func turnedOnHostsSurviveARoundTrip() throws {
        var settings = Settings.defaults
        settings.agents.hosts = ["bb"]
        #expect(try SettingsStore.decode(from: SettingsStore.encode(settings)).agents.hosts == ["bb"])
    }
}
