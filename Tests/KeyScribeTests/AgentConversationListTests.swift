import Foundation
@testable import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct AgentConversationListTests {
    private func model() -> AgentsSettingsModel {
        AgentsSettingsModel(
            describeTerminal: { _ in nil },
            agentsDir: FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-conversations-\(UUID().uuidString)"),
            connectors: [])
    }

    private func conversation(_ id: String, _ name: String, live: Bool, pid: Int, state: AgentLiveState = .idle) -> AgentConversation {
        AgentConversation(id: id, agent: "claude", pid: pid, cwd: "/src/\(name)", handle: name, state: state, connectorLive: live)
    }

    private func crowded(_ model: AgentsSettingsModel, workingFirst: Bool = false) {
        model.show(
            [
                conversation("a", "zeta", live: true, pid: 1, state: workingFirst ? .working : .idle),
                conversation("b", "alpha", live: true, pid: 2),
                conversation("c", "mid", live: false, pid: 3),
            ],
            candidates: [AgentCandidate(agent: "claude", pid: 9, startedAt: 5_000, cwd: "/src/found", setup: "/x/.claude")],
            disconnected: [conversation("d", "parked", live: false, pid: 4)])
    }

    @Test func theListGroupsWorkingConversationsApartFromTheRest() {
        let model = model()
        crowded(model)
        let groups = model.conversationGroups(matching: "")
        #expect(groups.connected.map(\.name) == ["alpha", "zeta"])
        #expect(groups.notConnected.map(\.name).contains("mid"))
        #expect(groups.notConnected.count == 2)
        #expect(groups.disconnected.map(\.name) == ["parked"])
    }

    @Test func aStatusChangeNeverReordersTheList() {
        let model = model()
        crowded(model)
        let before = model.conversationGroups(matching: "").connected.map(\.key)
        crowded(model, workingFirst: true)
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

    @Test func revealingAConversationOpensTheList() {
        let model = model()
        crowded(model)
        model.reveal(["c"])
        #expect(model.showingConversations)
        #expect(model.revealedKey == model.rows.first { $0.name == "mid" }?.key)
    }

    @Test func aConversationWaitingOnTheUserStandsOutAndAReadyOneDoesNot() {
        let model = model()
        model.show(
            [conversation("a", "zeta", live: true, pid: 1, state: .waitingApproval), conversation("b", "alpha", live: true, pid: 2)])
        #expect(model.rows.first { $0.name == "zeta" }?.needsYou == true)
        #expect(model.rows.first { $0.name == "alpha" }?.needsYou == false)
    }

    @Test func theSummaryCountsOnlyAvailableConversations() {
        let model = model()
        #expect(model.conversationsSummary == "None available")
        crowded(model)
        #expect(model.conversationsSummary == "2 available")
    }

    @Test func aFilteredListShowsOnlyTheAffectedConversationsUntilShowAllOrTheSheetCloses() {
        let model = model()
        crowded(model)
        let affected = model.conversationGroups(matching: "").notConnected.map(\.id)
        model.showOnly(affected, title: "affected")
        #expect(model.showingConversations)
        let filtered = model.conversationGroups(matching: "")
        #expect(filtered.connected.isEmpty && filtered.disconnected.isEmpty)
        #expect(filtered.notConnected.map(\.id) == affected)
        model.showAllConversations()
        #expect(!model.conversationGroups(matching: "").connected.isEmpty)
        model.showOnly(affected, title: "affected")
        model.showingConversations = false
        #expect(model.listFilter == nil)
    }

    @Test func aHealthyIntegrationSaysOnlyWhatIsAvailableAndAnyOtherLeadsWithItsSetup() {
        #expect(ConnectionSummary.line(setup: nil, available: 10) == "10 conversations available")
        #expect(ConnectionSummary.line(setup: nil, available: 1) == "1 conversation available")
        #expect(ConnectionSummary.line(setup: nil, available: 0) == "No conversations open")
        #expect(ConnectionSummary.line(setup: "Not set up", available: 0) == "Not set up")
        #expect(ConnectionSummary.line(setup: "Updating\u{2026}", available: 2) == "Updating\u{2026} \u{00B7} 2 conversations available")
    }

    @Test func openConversationsThatCannotReceiveYetAreNotCalledNoneOpen() {
        #expect(ConnectionSummary.line(setup: nil, available: 0, open: 2) == "2 open, none connected")
        #expect(ConnectionSummary.line(setup: nil, available: 0, open: 1) == "1 open, not connected")
        #expect(ConnectionSummary.line(setup: "Not set up", available: 0, open: 2) == "Not set up \u{00B7} 2 open, none connected")
        #expect(ConnectionSummary.line(setup: nil, available: 3, open: 5) == "3 conversations available")
        #expect(ConnectionSummary.line(setup: nil, available: 0, open: 0) == "No conversations open")
    }

    @Test func theFolderCountJoinsTheSummaryOnlyWhenThereIsMoreThanOneFolder() {
        #expect(ConnectionSummary.line(setup: nil, available: 10, folders: 1) == "10 conversations available")
        #expect(ConnectionSummary.line(setup: nil, available: 10, folders: 2) == "10 conversations available \u{00B7} 2 configuration folders")
    }

    @Test func conversationsAwaitingAReloadAreCountedWithTheStepThatConnectsThem() {
        #expect(ConnectionSummary.awaitingReload(1, reload: "/reload-plugins")
            == "1 conversation needs the connector loaded. Run /reload-plugins in it, or restart it.")
        #expect(ConnectionSummary.awaitingReload(8, reload: "/reload-plugins")
            == "8 conversations need the connector loaded. Run /reload-plugins in each, or restart them.")
        #expect(ConnectionSummary.awaitingReload(2, reload: nil) == "2 conversations haven\u{2019}t connected yet.")
    }

    @Test func everyIntegrationIsListedOnceWithItsHostAfterConnectorsOfItsOwn() {
        let model = AgentsSettingsModel(
            describeTerminal: { _ in nil },
            agentsDir: FileManager.default.temporaryDirectory.appendingPathComponent("ks-agent-conversations-\(UUID().uuidString)"),
            connectors: [], hosts: [AgentKind(id: "host", displayName: "Host", connectorName: "Host plugin")])
        #expect(model.integrationIDs == ["host"])
    }
}
