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

    @Test func otherReasonsOfferNoRetry() {
        #expect(AgentOutput.askLine(.noSuchRow(4), retry: .tell, names: names, current: nil) == "Not sent: there is no session 4")
    }

    @Test(arguments: ["two", "api", "web blue"])
    func eachSuggestedPhraseReachesTheConversationItNames(name: String) {
        let spoken = AgentRecipient.spokenNames(names, shared: [:])
        let tell = AgentOutput.Retry.tell.phrase(name).replacingOccurrences(of: "\u{2026}", with: "run the tests")
        #expect(AgentRecipient.resolve(AgentAddress.parse(tell, names: spoken), frozen: .init(id: "a", source: .current), rows: [], names: names)
            == .deliver(id: names[name]!, body: "run the tests", source: .spoken))
        let open = AgentOutput.Retry.open.phrase(name)
        #expect(AgentRecipient.resolve(AgentAddress.parse(open, names: spoken), frozen: .init(id: "a", source: .current), rows: [], names: names)
            == .open(id: names[name]!))
    }
}
