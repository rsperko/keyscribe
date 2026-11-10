import Foundation
import Testing
@testable import KeyScribeKit

private func conversation(_ id: String, _ handle: String) -> AgentConversation {
    AgentConversation(id: id, agent: "claude", pid: 1, cwd: "/tmp/\(handle)", handle: handle, state: .idle, connectorLive: true)
}

private let roster = [conversation("s-backend", "backend"), conversation("s-docs", "docs")]

private func facts(
    _ address: AgentAddress, _ resolution: AgentRecipient.Resolution,
    frozen: AgentRecipient.Frozen? = AgentRecipient.Frozen(id: "s-docs", source: .current)
) -> [String: String] {
    let list = AgentHistoryFacts.facts(address: address, resolution: resolution, frozen: frozen, conversations: roster)
    return Dictionary(list.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
}

struct AgentHistoryFactsTests {
    @Test func goingBackRecordsTheCommandAndTheRecipientItLeavesInPlace() {
        let list = AgentHistoryFacts.goBack(frozen: AgentRecipient.Frozen(id: "s-docs", source: .current), conversations: roster)
        #expect(list.map(\.label) == ["Command", "Default recipient"])
        #expect(list.map(\.value) == ["Go back", "docs"])
        #expect(AgentHistoryFacts.goBack(frozen: nil, conversations: roster).map(\.label) == ["Command"])
    }

    @Test func repeatingASummaryRecordsTheCommandAndTheRecipientItLeavesInPlace() {
        let list = AgentHistoryFacts.repeatSummary(frozen: AgentRecipient.Frozen(id: "s-docs", source: .current), conversations: roster)
        #expect(list.map(\.value) == ["Repeat that", "docs"])
    }

    @Test func aRenameRecordsTheConversationItsNewNameAndHowItWasChosen() {
        let list = AgentHistoryFacts.rename(
            frozen: AgentRecipient.Frozen(id: "s-docs", source: .front), to: "auth refactor", conversations: roster)
        #expect(list.map(\.label) == ["Command", "Conversation", "New name", "Chosen by"])
        #expect(list.map(\.value) == [
            "Rename", "docs \u{00B7} claude \u{00B7} s-docs", "auth refactor", "The conversation in front",
        ])
        #expect(AgentHistoryFacts.rename(frozen: nil, to: "x", conversations: roster).map(\.value)
            == ["Rename", "None resolved", "x"])
        #expect(AgentHistoryFacts.rename(frozen: nil, to: nil, conversations: roster).map(\.label) == ["Command", "Conversation"])
    }

    @Test func aStatusCheckRecordsTheConversationAndHowItWasChosenButNoAnswer() {
        let named = AgentHistoryFacts.status(
            address: .name("backend", body: ""), resolution: .select(id: "s-backend"), frozen: nil, conversations: roster)
        #expect(named.map(\.label) == ["Command", "Spoken address", "Conversation", "Chosen by"])
        #expect(named.map(\.value) == ["Check status", "backend", "backend \u{00B7} claude \u{00B7} s-backend", "Its name"])
        let current = AgentRecipient.Frozen(id: "s-docs", source: .current)
        let unnamed = AgentHistoryFacts.status(
            address: nil, resolution: .deliver(id: "s-docs", body: "", source: .current), frozen: current, conversations: roster)
        #expect(unnamed.first?.value == "Check status")
        #expect(unnamed.first { $0.label == "Chosen by" }?.value == "The current conversation")
        #expect(AgentHistoryFacts.whoNeedsMe().map(\.value) == ["Who needs me"])
    }

    @Test func anOpenByNameRecordsTheCommandAddressAndConversation() {
        let recorded = facts(.open(.name("backend", body: "")), .open(id: "s-backend"))
        #expect(recorded["Command"] == "Open")
        #expect(recorded["Spoken address"] == "backend")
        #expect(recorded["Conversation"] == "backend \u{00B7} claude \u{00B7} s-backend")
        #expect(recorded["Chosen by"] == "Its name")
    }

    @Test func aMessageToTheCurrentConversationNamesTheDefaultAndHowItWasChosen() {
        let recorded = facts(.none(body: "run the tests"), .deliver(id: "s-docs", body: "run the tests", source: .current))
        #expect(recorded["Command"] == "Send message")
        #expect(recorded["Spoken address"] == nil)
        #expect(recorded["Conversation"] == "docs \u{00B7} claude \u{00B7} s-docs")
        #expect(recorded["Chosen by"] == "The current conversation")
        #expect(recorded["Default recipient"] == "docs")
    }

    @Test func aFixedConversationRecordsThatTheModeChoseIt() {
        let recorded = facts(.none(body: "x"), .deliver(id: "s-docs", body: "x", source: .fixed))
        #expect(recorded["Chosen by"] == "The mode\u{2019}s fixed conversation")
    }

    @Test func aMessageToTheConversationInFrontRecordsThatItWasInFront() {
        let recorded = facts(.none(body: "x"), .deliver(id: "s-docs", body: "x", source: .front))
        #expect(recorded["Chosen by"] == "The conversation in front")
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
            frozen: nil, conversations: roster)
        #expect(list.contains(.init(label: "Conversation", value: "backend \u{00B7} claude \u{00B7} s-backend")))
        #expect(!list.contains { $0.label == "Default recipient" })
    }
}

struct AgentSpokenReplyEntryTests {
    @Test func aSpokenLineOnItsOwnIsAnEntryNamingWhoItCameFrom() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let reply = HistoryEntry.SpokenReply(at: at, conversation: "docs", text: "docs: Done.", connection: "Local")
        let entry = AgentHistoryFacts.spokenReplyEntry(id: "e1", mode: "Coding agent", reply: reply)
        #expect(entry.id == "e1")
        #expect(entry.timestamp == at)
        #expect(entry.modeName == "Coding agent")
        #expect(entry.summary == "Reply from docs")
        #expect(entry.spokenReply == reply)
        #expect(entry.heard.isEmpty && entry.result.isEmpty)
        #expect(entry.outcome == .command)
        #expect(!entry.cloudInvolved)
    }
}
