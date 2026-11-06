import Foundation
import Testing
@testable import KeyScribeKit

struct AgentRosterTests {
    private func conversation(
        _ id: String, _ handle: String, cwd: String = "/src/keyscribe", state: AgentLiveState = .idle, live: Bool = true,
        agent: String = "claude", title: String? = nil
    ) -> AgentConversation {
        AgentConversation(id: id, agent: agent, pid: 1, cwd: cwd, handle: handle, state: state, connectorLive: live, title: title)
    }

    @Test func theRecordingListPutsCurrentThenWaitingThenRecentlyUsedThenTheRestAlphabetically() {
        let at = { (seconds: Double) in Date(timeIntervalSince1970: seconds) }
        let directory = [
            conversation("a", "alpha"),
            conversation("b", "bravo", state: .waitingApproval),
            conversation("c", "charlie"),
            conversation("d", "delta", state: .waitingQuestion),
            conversation("e", "echo", state: .userDialog),
            conversation("f", "foxtrot"),
            conversation("g", "golf", state: .working),
            conversation("h", "hotel"),
        ]
        let used = ["b": at(10), "d": at(30), "c": at(20), "f": at(40), "h": at(50)]
        let ordered = AgentRoster.recordingOrder(directory, current: "h", lastUsed: used)
        #expect(ordered.map(\.id) == ["h", "d", "b", "e", "f", "c", "a", "g"])
    }

    @Test func withNothingUsedTheRecordingListIsCurrentThenWaitingThenAlphabetical() {
        let directory = [conversation("a", "alpha"), conversation("b", "bravo", state: .waitingQuestion), conversation("c", "charlie")]
        #expect(AgentRoster.recordingOrder(directory, current: nil, lastUsed: [:]).map(\.id) == ["b", "a", "c"])
        #expect(AgentRoster.recordingOrder(directory, current: "c", lastUsed: [:]).map(\.id) == ["c", "b", "a"])
    }

    @Test func rowsAreNumberedInTheirFrozenOrderAndNameTheirProject() {
        let frozen = [conversation("a", "keyscribe"), conversation("b", "chatplay", cwd: "/src/chatplay")]
        let roster = AgentRoster(frozen: frozen, live: frozen, recipient: nil)
        #expect(roster.rows.map(\.number) == [1, 2])
        #expect(roster.rows.map(\.name) == ["keyscribe", "chatplay"])
        #expect(roster.rows.map(\.detail) == ["keyscribe", "chatplay"])
        #expect(roster.recipientName == nil)
        #expect(roster.rows.allSatisfy { !$0.current })
    }

    @Test func theAgentsOwnTitleLeadsTheDetailWhenItSaysSomethingTheNameDoesNot() {
        let frozen = [
            conversation("a", "keyscribe", title: "Fix terminal focus after reconnect"),
            conversation("b", "chatplay", cwd: "/src/chatplay", title: "chatplay"),
        ]
        let roster = AgentRoster(frozen: frozen, live: frozen, recipient: nil)
        #expect(roster.rows.map(\.detail) == ["Fix terminal focus after reconnect \u{00B7} keyscribe", "chatplay"])
    }

    @Test func theAgentIsNamedOnlyWhenTheListMixesAgents() {
        let frozen = [conversation("a", "keyscribe"), conversation("b", "backend", cwd: "/src/backend", agent: "codex")]
        let roster = AgentRoster(frozen: frozen, live: frozen, recipient: nil)
        #expect(roster.rows.map(\.detail) == ["Claude \u{00B7} keyscribe", "Codex \u{00B7} backend"])
    }

    @Test func statesUpdateInPlaceWithoutRenumberingAndNewSessionsStayOut() {
        let frozen = [conversation("a", "keyscribe"), conversation("b", "chatplay")]
        let live = [conversation("c", "aardvark"), conversation("b", "chatplay", state: .working), conversation("a", "keyscribe")]
        let roster = AgentRoster(frozen: frozen, live: live, recipient: nil)
        #expect(roster.rows.map(\.id) == ["a", "b"])
        #expect(roster.rows.map(\.state) == ["Ready", "Working"])
    }

    @Test func aConversationThatEndedKeepsItsRowAndNameButCannotReceive() {
        let frozen = [conversation("a", "keyscribe"), conversation("b", "chatplay")]
        let roster = AgentRoster(frozen: frozen, live: [conversation("b", "chatplay")], recipient: AgentRecipient.Frozen(id: "a", source: .current))
        #expect(roster.rows[0] == .init(id: "a", number: 1, name: "keyscribe", detail: "keyscribe", state: "Ended", available: false, current: true))
        #expect(roster.rows[1].number == 2)
        #expect(roster.recipientName == "keyscribe")
    }

    @Test func theRecipientIsMarkedAndSaysWhereItCameFrom() {
        let frozen = [conversation("a", "keyscribe"), conversation("b", "chatplay")]
        let roster = AgentRoster(frozen: frozen, live: frozen, recipient: AgentRecipient.Frozen(id: "b", source: .current))
        #expect(roster.rows.map(\.current) == [false, true])
        #expect(roster.recipientName == "chatplay")
        #expect(roster.source == .current)
    }

    @Test func aRecipientOutsideTheListHighlightsNothing() {
        let frozen = [conversation("a", "keyscribe")]
        let roster = AgentRoster(frozen: frozen, live: frozen, recipient: AgentRecipient.Frozen(id: "z", source: .current))
        #expect(roster.recipientName == nil)
        #expect(roster.source == nil)
        #expect(roster.rows.allSatisfy { !$0.current })
    }

    @Test func stateLabelsSayWhetherItCanReceiveBeforeWhatItIsDoing() {
        #expect(AgentRoster.stateLabel(conversation("a", "k", state: .working, live: false)) == "Not connected")
        #expect(AgentRoster.stateLabel(conversation("a", "k", state: .idle)) == "Ready")
        #expect(AgentRoster.stateLabel(conversation("a", "k", state: .waitingApproval)) == "Waiting for approval")
        #expect(AgentRoster.stateLabel(conversation("a", "k", state: .waitingQuestion)) == "Waiting for an answer")
        #expect(AgentRoster.stateLabel(conversation("a", "k", state: .userDialog)) == "Dialog open")
        #expect(AgentRoster.stateLabel(conversation("a", "k", state: .disconnected)) == "Disconnected")
        #expect(AgentRoster.isAvailable(conversation("a", "k", state: .working)))
        #expect(!AgentRoster.isAvailable(conversation("a", "k", state: .disconnected)))
        #expect(!AgentRoster.isAvailable(conversation("a", "k", live: false)))
    }
}
