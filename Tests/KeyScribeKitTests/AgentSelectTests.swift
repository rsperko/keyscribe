import Foundation
import Testing
@testable import KeyScribeKit

struct AgentSelectTests {
    let names = ["keyscribe": "a", "keyscribe blue": "b", "backend": "c"]

    private func resolve(
        _ text: String, frozen: AgentRecipient.Frozen? = .init(id: "a", source: .current), rows: [String] = ["a", "b", "c"]
    ) -> AgentRecipient.Resolution {
        AgentRecipient.resolve(AgentAddress.parse(text, names: Array(names.keys)), frozen: frozen, rows: rows, names: names)
    }

    @Test(arguments: [
        "select backend", "Select backend.", "choose backend", "Choose the backend", "please select backend",
        "select backend please", "Select conversation three", "choose session 3", "Select conversation 3.",
    ])
    func selectingARecipientSelectsItAndSendsNothing(text: String) {
        let resolution = resolve(text)
        #expect(resolution == .select(id: "c"))
        #expect(resolution.makesCurrent == "c")
    }

    @Test func selectingAnUnknownRecipientHoldsAndSendsNothing() {
        #expect(resolve("select frontend") == .ask(body: "", reason: .unknownName("frontend")))
    }

    @Test(arguments: ["select backend rows where active is true", "choose backend over frontend for this"])
    func selectFollowedByMoreWordsIsAMessage(text: String) {
        #expect(resolve(text) == .deliver(id: "a", body: text, source: .current))
    }

    @Test(arguments: [
        ("backend", "backend"), ("Backend.", "backend"), ("please backend", "backend"), ("tell backend", "backend"),
        ("session two", "conversation 2"), ("Conversation 2", "conversation 2"),
    ])
    func aRecipientAloneHoldsWithASelectHint(text: String, said: String) {
        let resolution = resolve(text)
        #expect(resolution == .ask(body: "", reason: .sayToSelect(said)))
        #expect(resolution.makesCurrent == nil)
    }

    @Test(arguments: [("backend please", "backend"), ("Backend, please.", "backend"), ("tell backend please", "backend"),
                      ("conversation two please", "conversation 2")])
    func aRecipientWithOnlyPleaseHoldsWithASelectHint(text: String, said: String) {
        let resolution = resolve(text)
        #expect(resolution == .ask(body: "", reason: .sayToSelect(said)))
        #expect(resolution.makesCurrent == nil)
    }

    @Test(arguments: [
        "ask frontend what it needs from me", "Ask frontend whether it is done.", "please ask frontend what you need",
        "ask frontend if it is done", "ask frontend why it is stuck", "Ask frontend how it is going.",
        "ask frontend when they will finish", "ask frontend where it put the logs",
        "ask frontend what changed", "ask frontend how the deploy went", "Ask frontend why the build failed.",
    ])
    func askingAnUnknownConversationAQuestionHolds(text: String) {
        guard case .ask(_, .unknownName("frontend")) = resolve(text) else {
            Issue.record("expected a hold for an unknown name, got \(resolve(text))"); return
        }
    }

    @Test(arguments: [
        "ask clarifying questions first", "ask questions if anything is unclear", "ask me before you push",
        "ask questions if you get stuck", "ask frontend to run the tests", "ask again if it fails",
        "ask first if they need the logs", "ask the user whether to keep the schema", "ask questions how to proceed",
        "ask the frontend what it needs from me", "Ask yourself whether the cache is needed.",
    ])
    func askingWithoutAConversationIsStillAMessage(text: String) {
        #expect(resolve(text) == .deliver(id: "a", body: text, source: .current))
    }

    @Test(arguments: ["open first", "select first", "switch to later", "choose again"])
    func navigatingToAnAdverbThatNamesNothingHolds(text: String) {
        guard case .ask(_, .unknownName) = resolve(text) else {
            Issue.record("expected a hold for an unknown name, got \(resolve(text))"); return
        }
    }

    @Test func aRecipientFollowedByAMessageStillSends() {
        #expect(resolve("backend, run the tests") == .deliver(id: "c", body: "run the tests", source: .spoken))
    }

    @Test func askingWhatItNeedsSendsTheQuestion() {
        #expect(AgentStatusQuery.parse("ask backend what it needs from me", names: Array(names.keys)) == nil)
        #expect(resolve("ask backend what it needs from me") == .deliver(id: "c", body: "what it needs from me", source: .spoken))
    }

    @Test(arguments: ["Conversation 2 run the tests.", "tell conversation two run the tests", "Session 2 run the tests."])
    func conversationAndSessionAddressARowAlike(text: String) {
        #expect(resolve(text) == .deliver(id: "b", body: "run the tests.", source: .spoken)
            || resolve(text) == .deliver(id: "b", body: "run the tests", source: .spoken))
    }

    @Test(arguments: ["open conversation two", "Open session 2"])
    func openingARowByEitherNounOpensIt(text: String) {
        #expect(resolve(text) == .open(id: "b"))
    }

    @Test(arguments: ["open backend please", "Please open backend."])
    func politeOpenStillOpens(text: String) {
        #expect(resolve(text) == .open(id: "c"))
    }

    @Test func conversationFollowedByARowNumberIsReservedLikeSession() {
        #expect(AgentHandles.isReserved("conversation two"))
        #expect(AgentHandles.isReserved("conversation"))
        #expect(!AgentHandles.isReserved("conversation notes"))
    }
}
