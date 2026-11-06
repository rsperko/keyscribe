import Foundation
import Testing
@testable import KeyScribeKit

private func conversation(_ id: String, _ handle: String) -> AgentConversation {
    AgentConversation(id: id, agent: "claude", pid: 1, cwd: "/tmp/\(handle)", handle: handle, state: .idle, connectorLive: true)
}

private let roster = [conversation("s-backend", "backend"), conversation("s-docs", "docs")]

private func facts(
    _ address: AgentAddress, _ resolution: AgentRecipient.Resolution,
    frozen: AgentRecipient.Frozen? = AgentRecipient.Frozen(id: "s-docs", source: .current),
    delivery: Mode.Agent.Delivery = .submit
) -> [String: String] {
    let list = AgentHistoryFacts.facts(
        address: address, resolution: resolution, frozen: frozen, conversations: roster, delivery: delivery)
    return Dictionary(list.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
}

struct AgentHistoryFactsTests {
    @Test func anOpenByNameRecordsTheCommandAddressAndConversation() {
        let recorded = facts(.open(.name("backend", body: "")), .open(id: "s-backend"))
        #expect(recorded["Command"] == "Open")
        #expect(recorded["Spoken address"] == "backend")
        #expect(recorded["Conversation"] == "backend \u{00B7} claude \u{00B7} s-backend")
        #expect(recorded["Chosen by"] == "Its name")
        #expect(recorded["Delivery"] == nil)
    }

    @Test func aMessageToTheCurrentConversationNamesTheDefaultAndHowItWasChosen() {
        let recorded = facts(.none(body: "run the tests"), .deliver(id: "s-docs", body: "run the tests", source: .current))
        #expect(recorded["Command"] == "Send message")
        #expect(recorded["Spoken address"] == nil)
        #expect(recorded["Conversation"] == "docs \u{00B7} claude \u{00B7} s-docs")
        #expect(recorded["Chosen by"] == "The current conversation")
        #expect(recorded["Default recipient"] == "docs")
        #expect(recorded["Delivery"] == "Send")
    }

    @Test func aDraftModeRecordsThatItKeepsADraft() {
        let recorded = facts(.none(body: "x"), .deliver(id: "s-docs", body: "x", source: .fixed), delivery: .draft)
        #expect(recorded["Delivery"] == "Keep as a draft")
        #expect(recorded["Chosen by"] == "The mode\u{2019}s fixed conversation")
    }

    @Test func choosingARecipientBySessionNumberIsNotAMessage() {
        let recorded = facts(.row(2, body: ""), .select(id: "s-docs"))
        #expect(recorded["Command"] == "Choose recipient")
        #expect(recorded["Spoken address"] == "Session 2")
        #expect(recorded["Chosen by"] == "Its session number")
    }

    @Test func anUnresolvedAddressKeepsWhatWasSaidAndSaysNoConversationWasResolved() {
        let recorded = facts(.unresolved(spoken: "frontend", body: "ship it"), .ask(body: "ship it", reason: .unknownName("frontend")))
        #expect(recorded["Command"] == "Send message")
        #expect(recorded["Spoken address"] == "frontend")
        #expect(recorded["Conversation"] == "None resolved")
        #expect(recorded["Chosen by"] == nil)
        #expect(recorded["Default recipient"] == "docs")
    }

    @Test func aMisheardOpenStaysAnOpen() {
        let recorded = facts(.open(.nearMiss(spoken: "back and", name: "backend", body: "", unaddressed: nil)),
                             .ask(body: "", reason: .soundsLike("back and", name: "backend")))
        #expect(recorded["Command"] == "Open")
        #expect(recorded["Spoken address"] == "back and")
        #expect(recorded["Closest name"] == "backend")
    }

    @Test func anAmbiguousNameKeepsEveryCandidateSeenThen() {
        let recorded = facts(.ambiguous(spoken: "back", names: ["docs", "backend"], body: "x"),
                             .ask(body: "x", reason: .ambiguousName("back", matches: ["docs", "backend"])))
        #expect(recorded["Candidates"] == "backend, docs")
    }

    @Test func noDefaultRecipientIsRecordedWhenNoneWasFrozen() {
        let list = AgentHistoryFacts.facts(
            address: .name("backend", body: "x"), resolution: .deliver(id: "s-backend", body: "x", source: .spoken),
            frozen: nil, conversations: roster, delivery: .submit)
        #expect(list.contains(.init(label: "Conversation", value: "backend \u{00B7} claude \u{00B7} s-backend")))
        #expect(!list.contains { $0.label == "Default recipient" })
    }
}
