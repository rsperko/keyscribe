import Foundation
@testable import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct AgentSendToTests {
    private func model() -> AgentsSettingsModel {
        AgentsSettingsModel(
            describeTerminal: { _ in nil },
            agentsDir: FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-send-to-\(UUID().uuidString)"),
            connectors: [])
    }

    private func conversation(_ id: String, _ name: String, live: Bool, pid: Int, state: AgentLiveState = .idle) -> AgentConversation {
        AgentConversation(id: id, agent: "claude", pid: pid, cwd: "/src/\(name)", handle: name, state: state, connectorLive: live)
    }

    private func crowded(_ model: AgentsSettingsModel, current: String? = "b", workingFirst: Bool = false) {
        model.show(
            [
                conversation("a", "zeta", live: true, pid: 1, state: workingFirst ? .working : .idle),
                conversation("b", "alpha", live: true, pid: 2),
                conversation("c", "mid", live: false, pid: 3),
            ],
            current: current,
            candidates: [AgentCandidate(agent: "claude", pid: 9, startedAt: 5_000, cwd: "/src/found", setup: "/x/.claude")],
            disconnected: [conversation("d", "parked", live: false, pid: 4)])
    }

    @Test func withNothingChosenInstructionsFollowTheConversationInFront() {
        let model = model()
        crowded(model, current: nil)
        #expect(model.destination == .front)
        #expect(model.destination.title == "Conversation in front")
        #expect(model.sendToExample == "\u{201C}Run the unit tests\u{201D} goes to the conversation in front of you.")
    }

    @Test func aChosenConversationIsTheDestinationAndItsExampleSaysTheFrontDoesNotMatter() {
        let model = model()
        crowded(model)
        #expect(model.destination == .conversation("alpha"))
        #expect(model.sendToExample?.contains("goes to alpha, even when another conversation is in front") == true)
    }

    @Test func choosingSetsTheDestinationAndOnlyAsksTheHubToChoose() {
        let model = model()
        crowded(model, current: nil)
        var chosen: [String?] = []
        var shown: [String] = []
        model.onChoose = { id in
            chosen.append(id)
            self.crowded(model, current: id)
        }
        model.onShow = { shown.append($0) }
        model.choose("a")
        #expect(model.destination == .conversation("zeta"))
        model.choose(nil)
        #expect(model.destination == .front)
        #expect(chosen == ["a", nil])
        #expect(shown.isEmpty)
    }

    @Test func choosingTheDestinationAlreadyChosenDoesNothing() {
        let model = model()
        crowded(model)
        var chosen: [String?] = []
        model.onChoose = { chosen.append($0) }
        model.choose("b")
        #expect(chosen.isEmpty)
    }

    @Test func aChosenConversationThatCannotReceiveIsKeptAndSaysWhy() {
        let model = model()
        crowded(model, current: "c")
        guard case .unavailable(let name, let problem) = model.destination else {
            Issue.record("expected an unavailable destination")
            return
        }
        #expect(name == "mid")
        #expect(problem.contains("held, not sent elsewhere"))
        #expect(model.sendToExample == nil)
        crowded(model, current: "d")
        #expect(model.destination.title == "parked")
        #expect(model.destination != .front)
    }

    @Test func renamingAChooserRowNeverChangesTheDestination() {
        let model = model()
        crowded(model)
        var chosen: [String?] = []
        model.onChoose = { chosen.append($0) }
        model.onRename = { _, _ in }
        #expect(model.rename("a", to: "api"))
        #expect(chosen.isEmpty)
        #expect(model.destination == .conversation("alpha"))
    }

    @Test func theChooserOffersWorkingConversationsAndKeepsTheRestApart() {
        let model = model()
        crowded(model)
        let groups = model.conversationGroups(matching: "")
        #expect(groups.connected.map(\.name) == ["alpha", "zeta"])
        #expect(groups.notConnected.map(\.name).contains("mid"))
        #expect(groups.notConnected.count == 2)
        #expect(groups.disconnected.map(\.name) == ["parked"])
    }

    @Test func aChosenConversationThatCannotReceiveIsNotOfferedAsWorking() {
        let model = model()
        crowded(model, current: "c")
        #expect(!model.conversationGroups(matching: "").connected.contains { $0.name == "mid" })
    }

    @Test func aStatusChangeNeverReordersTheChooser() {
        let model = model()
        crowded(model)
        let before = model.conversationGroups(matching: "").connected.map(\.key)
        crowded(model, current: "a", workingFirst: true)
        #expect(model.conversationGroups(matching: "").connected.map(\.key) == before)
    }

    @Test func searchReachesEveryGroupByNameAgentAndFolder() {
        let model = model()
        crowded(model)
        #expect(model.conversationGroups(matching: "PARK").disconnected.map(\.name) == ["parked"])
        #expect(model.conversationGroups(matching: "src/found").notConnected.count == 1)
        let byAgent = model.conversationGroups(matching: "claude")
        #expect(byAgent.connected.count == 2 && byAgent.disconnected.count == 1)
        #expect(model.conversationGroups(matching: "nothing like it") == .init(connected: [], notConnected: [], disconnected: []))
    }

    @Test func revealingAConversationOpensTheChooser() {
        let model = model()
        crowded(model)
        model.reveal(["c"])
        #expect(model.showingChooser)
        #expect(model.revealedKey == model.rows.first { $0.name == "mid" }?.key)
    }

    @Test func aConversationWaitingOnTheUserStandsOutAndAReadyOneDoesNot() {
        let model = model()
        model.show(
            [conversation("a", "zeta", live: true, pid: 1, state: .waitingApproval), conversation("b", "alpha", live: true, pid: 2)],
            current: nil)
        #expect(model.rows.first { $0.name == "zeta" }?.needsYou == true)
        #expect(model.rows.first { $0.name == "alpha" }?.needsYou == false)
    }

    @Test func eachIntegrationKeepsItsSetupApartFromWhichConversationsAreAvailable() {
        #expect(ConnectionSummary.line(setup: "Not set up", isSetUp: false, available: 0, notConnected: 0) == "Not set up")
        #expect(ConnectionSummary.line(setup: "Connector installed", isSetUp: true, available: 0, notConnected: 0)
            == "Connector installed \u{00B7} No conversations open")
        #expect(ConnectionSummary.line(setup: "Connector installed", isSetUp: true, available: 4, notConnected: 2)
            == "Connector installed \u{00B7} 4 conversations available \u{00B7} 2 not connected")
        #expect(ConnectionSummary.line(setup: "Not set up", isSetUp: false, available: 0, notConnected: 3) == "Not set up \u{00B7} 3 not connected")
        #expect(ConnectionSummary.line(setup: "Connector installed", isSetUp: true, available: 1, notConnected: 0)
            == "Connector installed \u{00B7} 1 conversation available")
    }

    @Test func everyIntegrationIsListedOnceWithItsHostAfterConnectorsOfItsOwn() {
        let model = AgentsSettingsModel(
            describeTerminal: { _ in nil },
            agentsDir: FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-send-to-\(UUID().uuidString)"),
            connectors: [], hosts: [AgentKind(id: "host", displayName: "Host", connectorName: "Host plugin")])
        #expect(model.integrationIDs == ["host"])
    }
}
