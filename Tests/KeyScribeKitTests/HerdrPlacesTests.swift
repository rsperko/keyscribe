import Foundation
import Testing
@testable import KeyScribeKit

struct HerdrPlacesTests {
    private let socket = "/tmp/herdr.sock"

    private func workspaces(_ items: [(id: String, label: String?)]) -> String {
        let rows = items.map { item in
            item.label.map { #"{"workspace_id":"\#(item.id)","label":"\#($0)","number":1}"# } ?? #"{"workspace_id":"\#(item.id)","number":1}"#
        }
        return #"{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[\#(rows.joined(separator: ","))]}}"#
    }

    private func tabs(_ items: [(id: String, label: String, number: Int)]) -> String {
        let rows = items.map { #"{"tab_id":"\#($0.id)","workspace_id":"w1","label":"\#($0.label)","number":\#($0.number)}"# }
        return #"{"id":"cli:tab:list","result":{"tabs":[\#(rows.joined(separator: ","))],"type":"tab_list"}}"#
    }

    private struct Pane {
        var id: String
        var tab = "w1:t1"
        var workspace = "w1"
        var label: String?
        var agent: String?
        var session: (kind: String, value: String)?

        var json: String {
            var fields = [#""pane_id":"\#(id)""#, #""tab_id":"\#(tab)""#, #""workspace_id":"\#(workspace)""#, #""terminal_title":"Generated title""#]
            if let label { fields.append(#""label":"\#(label)""#) }
            if let agent { fields.append(#""agent":"\#(agent)""#) }
            if let session, let agent {
                fields.append(#""agent_session":{"agent":"\#(agent)","kind":"\#(session.kind)","source":"herdr:\#(agent)","value":"\#(session.value)"}"#)
            }
            return "{" + fields.joined(separator: ",") + "}"
        }
    }

    private func panes(_ items: [Pane]) -> String {
        #"{"id":"cli:pane:list","result":{"panes":[\#(items.map(\.json).joined(separator: ","))]}}"#
    }

    private func listing(
        panes items: [Pane], tabs tabItems: [(id: String, label: String, number: Int)] = [("w1:t1", "1", 1)],
        workspaces workspaceItems: [(id: String, label: String?)] = [("w1", "cos")]
    ) throws -> HerdrPlaces.Listing {
        try #require(HerdrPlaces.listing(panes: panes(items), tabs: tabs(tabItems), workspaces: workspaces(workspaceItems)))
    }

    private func lookup(
        _ agent: String, _ native: String, in listing: HerdrPlaces.Listing, socket: String = "/tmp/herdr.sock",
        current: HerdrPlaces.CurrentPane? = nil
    ) -> HerdrPlaces.Association {
        HerdrPlaces.place(agent: agent, native: native, in: listing, socket: socket) { current }
    }

    private func found(_ association: HerdrPlaces.Association) -> AgentPlace? {
        if case .found(let place) = association { place } else { nil }
    }

    @Test func aPaneFoundByItsAgentSessionCarriesItsLabelsDeepestFirst() throws {
        let listing = try listing(
            panes: [Pane(id: "w1:p1", label: "architect", agent: "claude", session: ("id", "abc"))],
            tabs: [("w1:t1", "backend", 1)])
        let place = try #require(found(lookup("claude", "abc", in: listing)))
        #expect(place.labels.map(\.text) == ["architect", "backend", "cos"])
        #expect(place.labels.map(\.level) == [.pane, .tab, .workspace])
        #expect(place.surface == "herdr")
    }

    @Test func aTabStillOnItsDefaultNumberAndAPaneNeverRenamedGiveNoLabel() throws {
        let listing = try listing(panes: [Pane(id: "w1:p1", agent: "claude", session: ("id", "abc"))])
        let place = try #require(found(lookup("claude", "abc", in: listing)))
        #expect(place.labels.map(\.text) == ["cos"])
    }

    @Test func aWorkspaceWithoutALabelLeavesNoLabelButStillAPlace() throws {
        let listing = try listing(panes: [Pane(id: "w1:p1", agent: "claude", session: ("id", "abc"))], workspaces: [("w1", nil)])
        let place = try #require(found(lookup("claude", "abc", in: listing)))
        #expect(place.labels.isEmpty)
    }

    @Test func aPiSessionIsFoundByTheIdInItsSessionFileName() throws {
        let path = "/Users/me/.pi/agent/sessions/--Users-me-home--/2026-11-02T19-48-59-803Z_01a19dce-d31a.jsonl"
        let listing = try listing(panes: [Pane(id: "w1:p3", agent: "pi", session: ("path", path))])
        #expect(found(lookup("pi", "01a19dce-d31a", in: listing)) != nil)
        #expect(found(lookup("pi", "2026-11-02T19-48-59-803Z", in: listing)) == nil)
    }

    @Test func anotherAgentsSessionWithTheSameIdIsNeverTaken() throws {
        let listing = try listing(panes: [Pane(id: "w1:p1", label: "architect", agent: "pi", session: ("id", "abc"))])
        #expect(found(lookup("claude", "abc", in: listing)) == nil)
    }

    @Test func thePaneFromTheAgentsEnvironmentIsUsedOnlyWhenHerdrHasNotRecognisedASessionThere() throws {
        let listing = try listing(panes: [
            Pane(id: "w1:p1", label: "builder"),
            Pane(id: "w1:p2", label: "architect", agent: "claude", session: ("id", "other")),
            Pane(id: "w1:p3", label: "notes", agent: "pi"),
        ])
        #expect(found(lookup("claude", "abc", in: listing, current: .pane("w1:p1")))?.labels.first?.text == "builder")
        #expect(lookup("claude", "abc", in: listing, current: .pane("w1:p2")) == .unresolved)
        #expect(lookup("claude", "abc", in: listing, current: .pane("w1:p3")) == .unresolved)
        #expect(lookup("claude", "abc", in: listing, current: .pane("w1:p9")) == .unresolved)
    }

    @Test func aMovedPaneWithoutASessionIsFoundThroughTheIdHerdrResolvesForItsOldOne() throws {
        let listing = try listing(
            panes: [Pane(id: "w2:p4", tab: "w2:t1", workspace: "w2", label: "architect")],
            tabs: [("w2:t1", "1", 1)], workspaces: [("w2", "atlas")])
        let place = try #require(found(lookup("claude", "abc", in: listing, current: .pane("w2:p4"))))
        #expect(place.labels.map(\.text) == ["architect", "atlas"])
    }

    @Test func onlyAPaneHerdrSaysIsGoneOrNoPaneToAskAboutConfirmsThereIsNoPlace() throws {
        let listing = try listing(panes: [Pane(id: "w1:p1", label: "builder")])
        #expect(lookup("claude", "abc", in: listing, current: nil) == .absent)
        #expect(lookup("claude", "abc", in: listing, current: .gone) == .absent)
        #expect(lookup("claude", "abc", in: listing, current: .unreadable) == .unresolved)
    }

    @Test func aMovedPaneIsFoundByItsSessionNotItsStaleEnvironmentId() throws {
        let listing = try listing(
            panes: [
                Pane(id: "w1:p1", label: "someone else"),
                Pane(id: "w2:p4", tab: "w2:t1", workspace: "w2", label: "architect", agent: "claude", session: ("id", "abc")),
            ],
            tabs: [("w1:t1", "1", 1), ("w2:t1", "1", 1)], workspaces: [("w1", "cos"), ("w2", "atlas")])
        let place = try #require(found(lookup("claude", "abc", in: listing, current: .pane("w1:p1"))))
        #expect(place.labels.map(\.text) == ["architect", "atlas"])
    }

    @Test func twoPanesClaimingOneSessionLeaveItUnresolved() throws {
        let listing = try listing(panes: [
            Pane(id: "w1:p1", label: "one", agent: "claude", session: ("id", "abc")),
            Pane(id: "w1:p2", label: "two", agent: "claude", session: ("id", "abc")),
        ])
        #expect(lookup("claude", "abc", in: listing) == .unresolved)
    }

    @Test func herdrsAnswerForTheCurrentPaneIsReadAsAPaneAGoneOneOrUnreadable() {
        #expect(HerdrPlaces.currentPane((0, #"{"id":"cli:pane:current","result":{"pane":{"pane_id":"w2:p4"}}}"#)) == .pane("w2:p4"))
        #expect(HerdrPlaces.currentPane((1, #"{"error":{"code":"pane_not_found","message":"pane not found"},"id":"cli:pane:current"}"#)) == .gone)
        #expect(HerdrPlaces.currentPane((1, #"{"error":{"code":"server_unavailable"}}"#)) == .unreadable)
        #expect(HerdrPlaces.currentPane((1, "")) == .unreadable)
        #expect(HerdrPlaces.currentPaneCommand(socket: "/s", pane: "w1:p1", executable: "/bin/herdr")
            == ["/usr/bin/env", "HERDR_SOCKET_PATH=/s", "HERDR_PANE_ID=w1:p1", "/bin/herdr", "pane", "current"])
    }

    @Test func containersAreScopedByTheServerSoTwoServersNeverShareAPlace() throws {
        let listing = try listing(panes: [Pane(id: "w1:p1", agent: "claude", session: ("id", "abc"))])
        let first = try #require(found(lookup("claude", "abc", in: listing, socket: "/a.sock")))
        let second = try #require(found(lookup("claude", "abc", in: listing, socket: "/b.sock")))
        #expect(Set(first.containers).isDisjoint(with: second.containers))
        #expect(first.labels[0].container != second.labels[0].container)
    }

    @Test func unreadableOutputIsNoListing() {
        #expect(HerdrPlaces.listing(panes: "not json", tabs: tabs([]), workspaces: workspaces([])) == nil)
        #expect(HerdrPlaces.listing(panes: panes([]), tabs: "", workspaces: workspaces([])) == nil)
        #expect(HerdrPlaces.listing(panes: panes([]), tabs: tabs([]), workspaces: #"{"result":{}}"#) == nil)
    }
}

struct HerdrPlaceCommandsTests {
    @Test func listingsAskTheServerOnTheSocketWithoutTheAgentsOwnPane() {
        let commands = HerdrPlaces.listCommands(socket: "/s.sock", executable: "/bin/herdr")
        #expect(commands.panes == ["/usr/bin/env", "-u", "HERDR_PANE_ID", "HERDR_SOCKET_PATH=/s.sock", "/bin/herdr", "pane", "list"])
        #expect(commands.tabs.suffix(2) == ["tab", "list"])
        #expect(commands.workspaces.suffix(2) == ["workspace", "list"])
    }
}
