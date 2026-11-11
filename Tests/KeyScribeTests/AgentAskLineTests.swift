import Testing
import KeyScribeKit
@testable import KeyScribeApp

@MainActor
struct AgentAskLineTests {
    let names = ["two": "a", "api": "b", "web blue": "c"]

    @Test func anUnknownNameWithNoConversationToOfferSaysOnlyThat() {
        #expect(AgentOutput.askLine(.unknownName("architect"), retry: .tell, names: [:], current: nil)
            == "Not sent: no conversation named \u{201C}architect\u{201D}")
    }

    @Test func theRetryNamesTheHighlightedConversationElseTheFirstAlphabetically() {
        #expect(AgentOutput.example(names: names, current: "c") == "web blue")
        #expect(AgentOutput.example(names: names, current: nil) == "api")
        #expect(AgentOutput.example(names: names, current: "gone") == "api")
    }

    @Test func aWordShownOnAConversationOffersThatConversationOnlyWhileItCanBeReached() {
        let reason = AgentRecipient.AskReason.shownOn("marvin", name: "cos", as: "herdr pane title")
        #expect(AgentOutput.askLine(reason, retry: .tell, names: ["cos": "a", "api": "b"], current: "b")
            == "Not sent: \u{201C}marvin\u{201D} is the herdr pane title of \u{201C}cos\u{201D}. Try \u{201C}tell cos, \u{2026}\u{201D}")
        #expect(AgentOutput.askLine(reason, retry: .tell, names: ["api": "b"], current: "b")
            == "Not sent: \u{201C}marvin\u{201D} is the herdr pane title of \u{201C}cos\u{201D}")
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
        #expect(AgentOutput.askLine(.noSuchRow(4), retry: .tell, names: names, current: nil) == "Not sent: there is no conversation 4")
    }

    @Test func aRecipientSaidAloneTeachesSelect() {
        let line = "Say \u{201C}select backend\u{201D} to choose it. Nothing sent."
        #expect(AgentOutput.askLine(.sayToSelect("backend"), retry: .tell, names: names, current: nil) == line)
        #expect(AgentOutput.openAskLine(.sayToSelect("backend")) == line)
    }

    @Test func aSelectRetryRepeatsSelect() {
        let text = "select frontend"
        #expect(AgentOutput.Retry.matching(text, AgentAddress.parse(text, names: ["chief"])) == .select)
        #expect(AgentOutput.askLine(.unknownName("frontend"), retry: .select, names: ["chief": "a"], current: nil)
            == "Not sent: no conversation named \u{201C}frontend\u{201D}. Try \u{201C}select chief\u{201D}")
    }

    @Test(arguments: ["two", "api", "web blue"])
    func eachSuggestedPhraseReachesTheConversationItNames(name: String) {
        let spoken = AgentRecipient.spokenNames(names, shared: [:])
        let tell = AgentOutput.Retry.tell.phrase(name).replacingOccurrences(of: "\u{2026}", with: "run the tests")
        #expect(AgentRecipient.resolve(AgentAddress.parse(tell, names: spoken), frozen: .init(id: "a", source: .current), rows: [], names: names)
            == .deliver(id: names[name]!, body: "run the tests", source: .spoken))
        let ask = AgentOutput.Retry.ask.phrase(name).replacingOccurrences(of: "\u{2026}", with: "what is left")
        #expect(AgentRecipient.resolve(AgentAddress.parse(ask, names: spoken), frozen: .init(id: "a", source: .current), rows: [], names: names)
            == .deliver(id: names[name]!, body: "what is left", source: .spoken))
        let open = AgentOutput.Retry.open.phrase(name)
        #expect(AgentRecipient.resolve(AgentAddress.parse(open, names: spoken), frozen: .init(id: "a", source: .current), rows: [], names: names)
            == .open(id: names[name]!))
    }
}
