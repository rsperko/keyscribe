import Foundation
import Testing
@testable import KeyScribeKit

struct AgentDirectoryPlaceTests {
    private func session(_ agent: String, _ id: String, pid: Int = 10, cwd: String = "/src/home", name: String? = nil) -> AgentSession {
        AgentSession(agent: agent, id: id, pid: pid, cwd: cwd, explicitName: name, state: .idle, startedAt: pid * 100)
    }

    private func place(pane: String? = nil, paneId: String = "p1", workspace: String? = "cos", workspaceId: String = "w1", socket: String = "/s") -> AgentPlace {
        let paneKey = "\(socket)#pane:\(paneId)", tabKey = "\(socket)#tab:\(workspaceId):t1", workspaceKey = "\(socket)#workspace:\(workspaceId)"
        var labels: [AgentPlace.Label] = []
        if let pane { labels.append(.init(text: pane, level: .pane, container: paneKey)) }
        if let workspace { labels.append(.init(text: workspace, level: .workspace, container: workspaceKey)) }
        return AgentPlace(surface: "herdr", labels: labels, containers: [paneKey, tabKey, workspaceKey])
    }

    private func handles(_ directory: AgentDirectory) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (directory.conversations + directory.disconnected).map { ($0.id, $0.handle) })
    }

    @Test func aPaneLabelNamesTheConversationInsteadOfItsFolder() {
        var directory = AgentDirectory()
        directory.update(entries: [session("claude", "a")], live: [], places: ["claude:a": place(pane: "Architect")])
        #expect(directory.handles == ["architect"])
        #expect(directory.conversations[0].nameSource == .place)
        #expect(directory.conversations[0].placeName == AgentPlaceName(surface: "herdr", level: .pane, label: "Architect"))
    }

    @Test func theAgentsOwnNameAndAKeyScribeNameBothWinOverThePlace() {
        var directory = AgentDirectory(chosen: ["claude:b": "builder"])
        directory.update(
            entries: [session("claude", "a", name: "tracker"), session("claude", "b", pid: 20)], live: [],
            places: ["claude:a": place(pane: "architect"), "claude:b": place(pane: "reviewer", paneId: "p2")])
        #expect(handles(directory) == ["claude:a": "tracker", "claude:b": "builder"])
        #expect(directory.conversations.first { $0.id == "claude:a" }?.nameSource == .agent)
        #expect(directory.conversations.first { $0.id == "claude:b" }?.nameSource == .chosen)
        #expect(directory.conversations.first { $0.id == "claude:a" }?.placeName?.label == "architect")
    }

    @Test func aLoneConversationTakesTheWorkspaceNameAsItIs() {
        var directory = AgentDirectory()
        directory.update(entries: [session("claude", "a")], live: [], places: ["claude:a": place()])
        #expect(directory.handles == ["cos"])
        #expect(directory.sharedPlaceNames.isEmpty)
    }

    @Test func aWorkspaceHoldingTwoAgentsNamesEachByItsAgentAndTheBareNameIsShared() {
        var directory = AgentDirectory()
        directory.update(
            entries: [session("claude", "a"), session("pi", "b", pid: 20)], live: [],
            places: ["claude:a": place(), "pi:b": place(paneId: "p2")])
        #expect(handles(directory) == ["claude:a": "cos claude", "pi:b": "cos pi"])
        #expect(directory.sharedPlaceNames == ["cos": AgentRecipient.SharedName(names: ["cos claude", "cos pi"])])
    }

    @Test func aSiblingWithItsOwnPaneNameStillMakesTheWorkspaceNameShared() {
        var directory = AgentDirectory()
        directory.update(
            entries: [session("claude", "a"), session("pi", "b", pid: 20)], live: [],
            places: ["claude:a": place(), "pi:b": place(pane: "pi", paneId: "p2")])
        #expect(handles(directory) == ["claude:a": "cos claude", "pi:b": "pi"])
        #expect(directory.sharedPlaceNames == ["cos": AgentRecipient.SharedName(names: ["cos claude", "pi"])])
    }

    @Test func twoConversationsOfOneAgentInAWorkspaceFallBackToADistinguishingWord() {
        var directory = AgentDirectory()
        directory.update(
            entries: [session("claude", "a"), session("claude", "b", pid: 20)], live: [],
            places: ["claude:a": place(), "claude:b": place(paneId: "p2")])
        #expect(Set(directory.handles) == ["cos claude", "cos claude blue"])
        #expect(directory.sharedPlaceNames["cos"] == AgentRecipient.SharedName(names: ["cos claude", "cos claude blue"], tellApartIn: "herdr"))
    }

    @Test func aQualifiedNameStaysAfterTheSiblingClosesSoTheFullNameKeepsWorking() {
        var directory = AgentDirectory()
        let places = ["claude:a": place(), "pi:b": place(paneId: "p2")]
        directory.update(entries: [session("claude", "a")], live: [], places: places)
        #expect(directory.handles == ["cos"])
        directory.update(entries: [session("claude", "a"), session("pi", "b", pid: 20)], live: [], places: places)
        #expect(handles(directory)["claude:a"] == "cos claude")
        directory.update(entries: [session("claude", "a"), session("pi", "b", pid: 20)], live: [], excluded: ["pi:b"], places: places)
        #expect(handles(directory) == ["claude:a": "cos claude", "pi:b": "cos pi"])
        directory.update(entries: [session("claude", "a")], live: [], places: places)
        #expect(directory.handles == ["cos claude"])
        #expect(directory.sharedPlaceNames == ["cos": AgentRecipient.SharedName(names: ["cos claude"])])
    }

    @Test func aNewConversationAloneUnderTheLabelIsNotQualifiedByAnEarlierCollision() {
        var directory = AgentDirectory()
        let places = ["claude:a": place(), "pi:b": place(paneId: "p2"), "claude:c": place(paneId: "p3")]
        directory.update(entries: [session("claude", "a"), session("pi", "b", pid: 20)], live: [], places: places)
        directory.update(entries: [session("claude", "c", pid: 30)], live: [], places: places)
        #expect(directory.handles == ["cos"])
    }

    @Test func sameNamedPlacesOnTwoServersShareOneSpokenNameWithEveryMember() {
        var directory = AgentDirectory()
        directory.update(
            entries: [session("claude", "a"), session("pi", "b", pid: 20), session("claude", "c", pid: 30), session("pi", "d", pid: 40)],
            live: [],
            places: [
                "claude:a": place(socket: "/one"), "pi:b": place(paneId: "p2", socket: "/one"),
                "claude:c": place(socket: "/two"), "pi:d": place(paneId: "p2", socket: "/two"),
            ])
        #expect(directory.sharedPlaceNames["cos"]?.names.count == 4)
        #expect(directory.sharedPlaceNames["cos"]?.tellApartIn == "herdr")
    }

    @Test func aPlaceWithoutAnyLabelStillSaysWhereTheConversationRuns() {
        var directory = AgentDirectory()
        directory.update(entries: [session("claude", "a")], live: [], places: ["claude:a": place(workspace: nil)])
        #expect(directory.conversations[0].placeSurface == "herdr")
    }

    @Test func aReservedPaneLabelFallsThroughToTheWorkspace() {
        var directory = AgentDirectory()
        directory.update(entries: [session("claude", "a")], live: [], places: ["claude:a": place(pane: "Session 2")])
        #expect(directory.handles == ["cos"])
        #expect(directory.conversations[0].placeName?.level == .workspace)
    }

    @Test func aPlaceWithoutLabelsLeavesTheFolderName() {
        var directory = AgentDirectory()
        directory.update(entries: [session("claude", "a")], live: [], places: ["claude:a": place(workspace: nil)])
        #expect(directory.handles == ["home"])
        #expect(directory.conversations[0].nameSource == .folder)
        #expect(directory.conversations[0].placeName == nil)
    }

    @Test func renamingThePaneRenamesTheConversationAndRemovingTheLabelFallsBack() {
        var directory = AgentDirectory()
        directory.update(entries: [session("claude", "a")], live: [], places: ["claude:a": place(pane: "architect")])
        directory.update(entries: [session("claude", "a")], live: [], places: ["claude:a": place(pane: "planner")])
        #expect(directory.handles == ["planner"])
        directory.update(entries: [session("claude", "a")], live: [], places: ["claude:a": place()])
        #expect(directory.handles == ["cos"])
    }

    @Test func aReplacementConversationInTheSamePaneGetsTheSameName() {
        var directory = AgentDirectory()
        directory.update(entries: [session("claude", "a")], live: [], places: ["claude:a": place(pane: "architect")])
        directory.update(entries: [session("claude", "b", pid: 20)], live: [], places: ["claude:b": place(pane: "architect")])
        #expect(handles(directory) == ["claude:b": "architect"])
    }

    @Test func aPlaceNameNeverStealsAnotherConversationsName() {
        var directory = AgentDirectory()
        directory.update(entries: [session("claude", "a", cwd: "/src/architect")], live: [])
        directory.update(
            entries: [session("claude", "a", cwd: "/src/architect"), session("pi", "b", pid: 20)], live: [],
            places: ["pi:b": place(pane: "architect", paneId: "p2")])
        #expect(handles(directory) == ["claude:a": "architect", "pi:b": "architect blue"])
    }

    @Test func useDefaultNameDropsTheOverrideAndTheDefaultIsShownBeforehand() {
        var directory = AgentDirectory(chosen: ["claude:a": "builder"])
        let places = ["claude:a": place(pane: "architect")]
        directory.update(entries: [session("claude", "a")], live: [], places: places)
        #expect(directory.handles == ["builder"])
        let preview = directory.defaultName(for: "claude:a")
        #expect(preview?.name == "architect")
        #expect(preview?.source == .place)
        #expect(preview?.place == AgentPlaceName(surface: "herdr", level: .pane, label: "architect"))
        directory.useDefaultName("claude:a")
        #expect(directory.chosenNames.isEmpty)
        directory.update(entries: [session("claude", "a")], live: [], places: places)
        #expect(directory.handles == ["architect"])
    }

    @Test func theDefaultNameAvoidsANameAnotherConversationHolds() {
        var directory = AgentDirectory(chosen: ["claude:a": "builder"])
        directory.update(
            entries: [session("claude", "a"), session("pi", "b", pid: 20, name: "architect")], live: [],
            places: ["claude:a": place(pane: "architect")])
        #expect(directory.defaultName(for: "claude:a")?.name == "architect blue")
    }

    @Test func twoSeparatePlacesWithTheSameLabelAreQualifiedAndTheBareLabelAsks() {
        var directory = AgentDirectory()
        directory.update(
            entries: [session("claude", "a"), session("pi", "b", pid: 20)], live: [],
            places: ["claude:a": place(workspaceId: "w1"), "pi:b": place(paneId: "p2", workspaceId: "w2", socket: "/other")])
        #expect(handles(directory) == ["claude:a": "cos claude", "pi:b": "cos pi"])
        #expect(directory.sharedPlaceNames == ["cos": AgentRecipient.SharedName(names: ["cos claude", "cos pi"])])
    }

    @Test func aQualifiedNameSurvivesRestartingTheAppWhileItsConversationRuns() {
        var directory = AgentDirectory(remembered: [
            "claude:a": RememberedName(name: "cos claude", pid: 10, startedAt: 1000, native: "cos claude", agent: "claude"),
        ])
        directory.update(entries: [session("claude", "a")], live: [], running: { _ in true }, unplaced: ["claude:a"])
        #expect(directory.handles == ["cos claude"])
        directory.update(entries: [session("claude", "a")], live: [], running: { _ in true }, places: ["claude:a": place()])
        #expect(directory.handles == ["cos claude"])
    }

    @Test func aConversationWhosePlaceIsUncheckedKeepsItsLastNameWhileAnotherFollowsItsPlace() {
        var directory = AgentDirectory()
        let places = ["claude:a": place(pane: "architect"), "claude:b": place(pane: "builder", paneId: "p2")]
        directory.update(entries: [session("claude", "a"), session("claude", "b", pid: 20)], live: [], places: places)
        directory.update(entries: [session("claude", "a"), session("claude", "b", pid: 20)], live: [], unplaced: ["claude:a"])
        #expect(Set(directory.handles) == ["architect", "home"])
        #expect(directory.conversations.first { $0.id == "claude:a" }?.placeName?.label == "architect")
    }
}
