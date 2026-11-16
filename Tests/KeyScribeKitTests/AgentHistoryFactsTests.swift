import Foundation
import Testing
@testable import KeyScribeKit

private func conversation(_ id: String, _ handle: String) -> AgentConversation {
    AgentConversation(id: id, agent: "claude", pid: 1, cwd: "/tmp/\(handle)", handle: handle, state: .idle, connectorLive: true)
}

private let roster = [conversation("s-backend", "backend"), conversation("s-docs", "docs")]

private func facts(
    _ address: AgentAddress, _ resolution: AgentRecipient.Resolution,
    focused: String? = "s-docs"
) -> [String: String] {
    let list = AgentHistoryFacts.facts(address: address, resolution: resolution, focused: focused, conversations: roster)
    return Dictionary(list.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
}

struct AgentHistoryFactsTests {
    @Test func goingBackRecordsTheCommandAndTheConversationInFront() {
        let list = AgentHistoryFacts.goBack(focused: "s-docs", conversations: roster)
        #expect(list.map(\.label) == ["Command", "Conversation in front"])
        #expect(list.map(\.value) == ["Go back", "docs"])
        #expect(AgentHistoryFacts.goBack(focused: nil, conversations: roster).map(\.label) == ["Command"])
    }

    @Test func repeatingASummaryRecordsTheCommandAndTheConversationInFront() {
        let list = AgentHistoryFacts.repeatSummary(focused: "s-docs", conversations: roster)
        #expect(list.map(\.value) == ["Repeat that", "docs"])
    }

    @Test func aRenameRecordsTheConversationItsNewNameAndHowItWasChosen() {
        let list = AgentHistoryFacts.rename(
            focused: "s-docs", to: "auth refactor", conversations: roster)
        #expect(list.map(\.label) == ["Command", "Conversation", "New name", "Chosen by"])
        #expect(list.map(\.value) == [
            "Rename", "docs \u{00B7} claude \u{00B7} s-docs", "auth refactor", "The conversation in front",
        ])
        #expect(AgentHistoryFacts.rename(focused: nil, to: "x", conversations: roster).map(\.value)
            == ["Rename", "None resolved", "x"])
        #expect(AgentHistoryFacts.rename(focused: nil, to: nil, conversations: roster).map(\.label) == ["Command", "Conversation"])
    }

    @Test func aStatusCheckRecordsTheConversationAndHowItWasChosenButNoAnswer() {
        let named = AgentHistoryFacts.status(
            address: .name("backend", body: ""), resolution: .deliver(id: "s-backend", body: "", source: .spoken), focused: nil,
            conversations: roster)
        #expect(named.map(\.label) == ["Command", "Spoken address", "Conversation", "Chosen by"])
        #expect(named.map(\.value) == ["Check status", "backend", "backend \u{00B7} claude \u{00B7} s-backend", "Its name"])
        let unnamed = AgentHistoryFacts.status(
            address: nil, resolution: .deliver(id: "s-docs", body: "", source: .front), focused: "s-docs", conversations: roster)
        #expect(unnamed.first?.value == "Check status")
        #expect(unnamed.first { $0.label == "Chosen by" }?.value == "The conversation in front")
        #expect(!unnamed.contains { $0.label == "Conversation in front" })
        #expect(AgentHistoryFacts.allConversations().map(\.value) == ["Check status", "All conversations"])
    }

    @Test func anOpenByNameRecordsTheCommandAddressAndConversation() {
        let recorded = facts(.open(.name("backend", body: "")), .open(id: "s-backend"))
        #expect(recorded["Command"] == "Open")
        #expect(recorded["Spoken address"] == "backend")
        #expect(recorded["Conversation"] == "backend \u{00B7} claude \u{00B7} s-backend")
        #expect(recorded["Chosen by"] == "Its name")
    }

    @Test func aMessageToTheConversationInFrontNamesItAndHowItWasChosen() {
        let recorded = facts(.none(body: "run the tests"), .deliver(id: "s-docs", body: "run the tests", source: .front))
        #expect(recorded["Command"] == "Send message")
        #expect(recorded["Spoken address"] == nil)
        #expect(recorded["Conversation"] == "docs \u{00B7} claude \u{00B7} s-docs")
        #expect(recorded["Chosen by"] == "The conversation in front")
        #expect(recorded["Conversation in front"] == "docs")
    }

    @Test func aNumberAloneIsHeldAndRecordedAsAMessageThatResolvedNothing() {
        let recorded = facts(.row(2, body: ""), .ask(body: "", reason: .nameOnly("conversation 2")))
        #expect(recorded["Command"] == "Send message")
        #expect(recorded["Spoken address"] == "Conversation 2")
        #expect(recorded["Conversation"] == "None resolved")
    }

    @Test func anUnresolvedAddressKeepsWhatWasSaidAndSaysNoConversationWasResolved() {
        let recorded = facts(.unresolved(spoken: "frontend", body: "ship it"), .ask(body: "ship it", reason: .unknownName("frontend")))
        #expect(recorded["Command"] == "Send message")
        #expect(recorded["Spoken address"] == "frontend")
        #expect(recorded["Conversation"] == "None resolved")
        #expect(recorded["Chosen by"] == nil)
        #expect(recorded["Conversation in front"] == "docs")
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

    @Test func noConversationInFrontIsRecordedWhenNoneWasFocused() {
        let list = AgentHistoryFacts.facts(
            address: .name("backend", body: "x"), resolution: .deliver(id: "s-backend", body: "x", source: .spoken),
            focused: nil, conversations: roster)
        #expect(list.contains(.init(label: "Conversation", value: "backend \u{00B7} claude \u{00B7} s-backend")))
        #expect(!list.contains { $0.label == "Conversation in front" })
    }
}

struct AgentSpokenReplyEntryTests {
    @Test func aSpokenLineOnItsOwnIsAnEntryNamingWhoItCameFrom() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let reply = HistoryEntry.SpokenReply(at: at, conversation: "docs", text: "docs: Done.", connection: "Local")
        let entry = AgentHistoryFacts.spokenReplyEntry(id: "e1", mode: "Agent", reply: reply)
        #expect(entry.id == "e1")
        #expect(entry.timestamp == at)
        #expect(entry.modeName == "Agent")
        #expect(entry.summary == "Reply from docs")
        #expect(entry.spokenReply == reply)
        #expect(entry.heard.isEmpty && entry.result.isEmpty)
        #expect(entry.outcome == .command)
        #expect(!entry.cloudInvolved)
    }
}
