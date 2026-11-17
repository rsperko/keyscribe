import Foundation
import Testing
@testable import KeyScribeKit

struct AgentRosterTests {
    private func conversation(
        _ id: String, _ handle: String, cwd: String = "/src/keyscribe", state: AgentLiveState = .idle, live: Bool = true,
        agent: String = "claude", title: String? = nil, startedAt: Date? = nil
    ) -> AgentConversation {
        AgentConversation(
            id: id, agent: agent, pid: 1, cwd: cwd, handle: handle, state: state, connectorLive: live, title: title, startedAt: startedAt)
    }

    @Test func theRecordingListPutsWaitingThenRecentlyUsedThenTheRestAlphabetically() {
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
        let ordered = AgentRoster.recordingOrder(directory, lastUsed: used)
        #expect(ordered.map(\.id) == ["d", "b", "e", "h", "f", "c", "a", "g"])
    }

    @Test func aSessionStartedSinceTheLastUseRanksAsTheMostRecentOne() {
        let at = { (seconds: Double) in Date(timeIntervalSince1970: seconds) }
        let directory = [
            conversation("a", "alpha", startedAt: at(5)),
            conversation("b", "bravo", startedAt: at(25)),
            conversation("c", "charlie", startedAt: at(15)),
            conversation("d", "delta", state: .waitingApproval, startedAt: at(35)),
            conversation("e", "echo", state: .waitingQuestion, startedAt: at(5)),
        ]
        let used = ["a": at(20), "c": at(30), "e": at(10)]
        let ordered = AgentRoster.recordingOrder(directory, lastUsed: used)
        #expect(ordered.map(\.id) == ["d", "e", "c", "b", "a"])
    }

    @Test func withNothingUsedTheRecordingListIsWaitingThenAlphabetical() {
        let directory = [conversation("a", "alpha"), conversation("b", "bravo", state: .waitingQuestion), conversation("c", "charlie")]
        #expect(AgentRoster.recordingOrder(directory, lastUsed: [:]).map(\.id) == ["b", "a", "c"])
    }

    @Test func rowsAreNumberedInTheirFrozenOrderAndNameTheirProject() {
        let frozen = [conversation("a", "keyscribe"), conversation("b", "chatplay", cwd: "/src/chatplay")]
        let roster = AgentRoster(frozen: frozen, live: frozen, focused: nil)
        #expect(roster.rows.map(\.number) == [1, 2])
        #expect(roster.rows.map(\.name) == ["keyscribe", "chatplay"])
        #expect(roster.rows.map(\.detail) == ["keyscribe", "chatplay"])
        #expect(roster.targetName == nil)
        #expect(roster.rows.allSatisfy { !$0.target })
    }

    @Test func theAgentsOwnTitleLeadsTheDetailWhenItSaysSomethingTheNameDoesNot() {
        let frozen = [
            conversation("a", "keyscribe", title: "Fix terminal focus after reconnect"),
            conversation("b", "chatplay", cwd: "/src/chatplay", title: "chatplay"),
        ]
        let roster = AgentRoster(frozen: frozen, live: frozen, focused: nil)
        #expect(roster.rows.map(\.detail) == ["Fix terminal focus after reconnect \u{00B7} keyscribe", "chatplay"])
    }

    @Test func theAgentIsNamedOnlyWhenTheListMixesAgents() {
        let frozen = [conversation("a", "keyscribe"), conversation("b", "backend", cwd: "/src/backend", agent: "codex")]
        let roster = AgentRoster(frozen: frozen, live: frozen, focused: nil)
        #expect(roster.rows.map(\.detail) == ["Claude \u{00B7} keyscribe", "Codex \u{00B7} backend"])
    }

    @Test func statesUpdateInPlaceWithoutRenumberingAndNewSessionsStayOut() {
        let frozen = [conversation("a", "keyscribe"), conversation("b", "chatplay")]
        let live = [conversation("c", "aardvark"), conversation("b", "chatplay", state: .working), conversation("a", "keyscribe")]
        let roster = AgentRoster(frozen: frozen, live: live, focused: nil)
        #expect(roster.rows.map(\.id) == ["a", "b"])
        #expect(roster.rows.map(\.state) == ["Ready", "Working"])
    }

    @Test func aConversationThatEndedKeepsItsRowAndNameButCannotReceive() {
        let frozen = [conversation("a", "keyscribe"), conversation("b", "chatplay")]
        let roster = AgentRoster(frozen: frozen, live: [conversation("b", "chatplay")], focused: "a")
        #expect(roster.rows[0] == .init(id: "a", number: 1, name: "keyscribe", detail: "keyscribe", state: "Ended", available: false, target: true))
        #expect(roster.rows[1].number == 2)
        #expect(roster.targetName == "keyscribe")
    }

    @Test func theConversationInFrontIsMarked() {
        let frozen = [conversation("a", "keyscribe"), conversation("b", "chatplay")]
        let roster = AgentRoster(frozen: frozen, live: frozen, focused: "b")
        #expect(roster.rows.map(\.target) == [false, true])
        #expect(roster.targetName == "chatplay")
    }

    @Test func aConversationInFrontOutsideTheListHighlightsNothing() {
        let frozen = [conversation("a", "keyscribe")]
        let roster = AgentRoster(frozen: frozen, live: frozen, focused: "z")
        #expect(roster.targetName == nil)
        #expect(roster.rows.allSatisfy { !$0.target })
    }

    @Test func aNewConversationInFrontIsTheTargetAndHighlightsNoRow() {
        let frozen = [conversation("a", "keyscribe")]
        let roster = AgentRoster(frozen: frozen, live: frozen, focused: nil, starting: "a new bb conversation")
        #expect(roster.targetName == "a new bb conversation")
        #expect(roster.rows.allSatisfy { !$0.target })
    }

    @Test func anOpenDialogIsLabelledByThePromptsKindWhenItIsKnown() {
        let dialog = conversation("a", "k", state: .userDialog)
        #expect(AgentRoster.stateLabel(dialog, prompt: AgentPrompt(kind: "confirm")) == "Waiting for approval")
        #expect(AgentRoster.stateLabel(dialog, prompt: AgentPrompt(kind: "select")) == "Waiting for an answer")
        #expect(AgentRoster.stateLabel(dialog, prompt: AgentPrompt(kind: "custom")) == "Dialog open")
        #expect(AgentRoster.stateLabel(conversation("a", "k", state: .waitingQuestion), prompt: AgentPrompt(kind: "confirm")) == "Waiting for an answer")
        let roster = AgentRoster(frozen: [dialog], live: [dialog], focused: nil, prompts: ["a": AgentPrompt(kind: "confirm")])
        #expect(roster.rows.first?.state == "Waiting for approval")
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

    @Test func aDisconnectedConversationInFrontIsNamedAsDisconnectedNotLeftBlank() {
        let listed = AgentConversation(id: "a", agent: "claude", pid: 1, cwd: "/src/api", handle: "api", state: .idle, connectorLive: true)
        let away = AgentConversation(id: "b", agent: "claude", pid: 2, cwd: "/src/api", handle: "api blue", state: .idle, connectorLive: false)
        let roster = AgentRoster(frozen: [listed], live: [listed], focused: "b", disconnected: [away])
        #expect(roster.targetName == "api blue, disconnected")
        #expect(roster.rows.allSatisfy { !$0.target })
    }
}
