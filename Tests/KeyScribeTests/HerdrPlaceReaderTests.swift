import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct HerdrPlaceReaderTests {
    private static let outputs = [
        "pane": #"{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","title":"marvin","agent":"pi","agent_session":{"agent":"pi","kind":"id","value":"abc"}}]}}"#,
        "tab": #"{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","number":1}]}}"#,
        "workspace": #"{"result":{"workspaces":[{"workspace_id":"w1","label":"chief"}]}}"#,
        "agent": #"{"result":{"agents":[{"agent":"pi","pane_id":"w1:p1","name":"cos"}]}}"#,
    ]

    private func reader(failing: String? = nil) -> HerdrPlaceReader {
        HerdrPlaceReader(
            environment: { _ in [HerdrPlaces.socketKey: "/s", HerdrPlaces.executableKey: "/bin/herdr"] },
            serverExecutable: { nil },
            run: { command in
                let noun = command[command.count - 2]
                return noun == failing ? (1, "") : (0, Self.outputs[noun] ?? "")
            })
    }

    private let query = AgentPlaceQuery(id: "pi:abc", agent: "pi", native: "abc", pid: 7)

    @Test func theTitleAndAgentNameHerdrKeepsAreReadForThePlace() {
        guard case .found(let place)? = reader().read([query])[query.id] else {
            Issue.record("expected a place")
            return
        }
        #expect(place.labels.map(\.text) == ["marvin", "cos", "chief"])
    }

    @Test func anAgentListHerdrCouldNotGiveLeavesThePlaceUnknownNotUnnamed() {
        #expect(reader(failing: "agent").read([query])[query.id] == .unknown)
    }
}
