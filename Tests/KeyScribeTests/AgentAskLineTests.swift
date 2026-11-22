import Testing
import KeyScribeKit
@testable import KeyScribeApp

@MainActor
struct AgentAskLineTests {
    let names = ["two": "a", "api": "b", "web blue": "c"]

    @Test func anUnknownNameWithNoConversationToOfferSaysOnlyThat() {
        #expect(AgentOutput.askLine(.unknownName("architect"), retry: .tell, names: [:])
            == "No conversation named \u{201C}architect\u{201D}. Nothing sent.")
    }

    @Test func theRetryNamesOnlyTheConversationWhoseNameResemblesWhatWasSaid() {
        #expect(AgentOutput.askLine(.unknownName("web"), retry: .open, names: names)
            == "No conversation named \u{201C}web\u{201D}. Nothing sent. Try \u{201C}open web blue\u{201D}")
        #expect(AgentOutput.askLine(.unknownName("apl"), retry: .tell, names: names)
            == "No conversation named \u{201C}apl\u{201D}. Nothing sent. Try \u{201C}tell api, \u{2026}\u{201D}")
        #expect(AgentOutput.askLine(.unknownName("zebra"), retry: .tell, names: names)
            == "No conversation named \u{201C}zebra\u{201D}. Nothing sent.")
    }

    @Test func aWordShownOnAConversationOffersThatConversationOnlyWhileItCanBeReached() {
        let reason = AgentRecipient.AskReason.shownOn("marvin", name: "cos", as: "herdr pane title")
        #expect(AgentOutput.askLine(reason, retry: .tell, names: ["cos": "a", "api": "b"])
            == "\u{201C}marvin\u{201D} is the herdr pane title of \u{201C}cos\u{201D}. Nothing sent. Try \u{201C}tell cos, \u{2026}\u{201D}")
        #expect(AgentOutput.askLine(reason, retry: .tell, names: ["api": "b"])
            == "\u{201C}marvin\u{201D} is the herdr pane title of \u{201C}cos\u{201D}. Nothing sent.")
    }

    @Test func theRetryRepeatsAsk() {
        for (text, retry) in [
            ("Ask chief what is left", AgentOutput.Retry.ask), ("Please ask chief what is left", .ask),
            ("Tell chief to run the tests", .tell), ("chief, run the tests", .tell), ("Open chief", .open),
        ] {
            #expect(AgentOutput.Retry.matching(text, AgentAddress.parse(text, names: ["chief"])) == retry)
        }
    }

    @Test func otherReasonsOfferNoRetry() {
        #expect(AgentOutput.askLine(.noSuchRow(4), retry: .tell, names: names) == "There is no conversation 4. Nothing sent.")
    }

    @Test func adviceComesAfterNothingSentWithOnePeriodEach() {
        let shared = AgentRecipient.AskReason.sharedName("cos", matches: ["cos claude", "cos pi"], tellApartIn: "herdr")
        #expect(AgentOutput.askLine(shared) == "\u{201C}cos\u{201D} could be \u{201C}cos claude\u{201D} or \u{201C}cos pi\u{201D}. Nothing sent. Name the panes in herdr to tell them apart.")
        #expect(AgentOutput.askLine(.noBreak("docs"))
                == "Did you mean \u{201C}docs\u{201D}? Nothing sent. Say \u{201C}tell docs,\u{201D} with a pause, or \u{201C}tell docs to \u{2026}\u{201D}.")
        #expect(AgentOutput.openAskLine(shared)
                == "\u{201C}cos\u{201D} could be \u{201C}cos claude\u{201D} or \u{201C}cos pi\u{201D}. Name the panes in herdr to tell them apart.")
    }

    @Test func aConversationSaidAloneAsksForTheInstructionAndNeverTeachesSelect() {
        let line = AgentOutput.askLine(.nameOnly("backend"), retry: .tell, names: names)
        #expect(line == "Only a name was heard: \u{201C}backend\u{201D}. Nothing sent. Say your instruction after \u{201C}backend\u{201D}, or \u{201C}open backend\u{201D} to bring it forward.")
        #expect(!line.contains("select"))
    }

    @Test func nothingFocusedSaysNothingWasSent() {
        #expect(AgentOutput.askLine(.nothingFocused)
            == "No conversation focused. Nothing sent. Open one, or name a conversation in your instruction.")
    }

    @Test(arguments: ["two", "api", "web blue"])
    func eachSuggestedPhraseReachesTheConversationItNames(name: String) {
        let spoken = AgentRecipient.spokenNames(names, shared: [:])
        let tell = AgentOutput.Retry.tell.phrase(name).replacingOccurrences(of: "\u{2026}", with: "run the tests")
        #expect(AgentRecipient.resolve(AgentAddress.parse(tell, names: spoken), focused: "a", rows: [], names: names)
            == .deliver(id: names[name]!, body: "run the tests", source: .spoken))
        let ask = AgentOutput.Retry.ask.phrase(name).replacingOccurrences(of: "\u{2026}", with: "what is left")
        #expect(AgentRecipient.resolve(AgentAddress.parse(ask, names: spoken), focused: "a", rows: [], names: names)
            == .deliver(id: names[name]!, body: "what is left", source: .spoken))
        let open = AgentOutput.Retry.open.phrase(name)
        #expect(AgentRecipient.resolve(AgentAddress.parse(open, names: spoken), focused: "a", rows: [], names: names)
            == .open(id: names[name]!))
    }
}
