import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct InjectedIntegrationsTests {
    final class Facts: TerminalFacts, @unchecked Sendable {
        var table: [Int: TerminalProcess] = [:]

        func add(_ pid: Int, parent: Int, tty: String? = nil, _ name: String, app: String? = nil) -> Facts {
            table[pid] = TerminalProcess(pid: pid, parent: parent, tty: tty, arguments: [name], environment: [:], executable: name, app: app)
            return self
        }

        func process(_ pid: Int) -> TerminalProcess? { table[pid] }
        func processes(named name: String) -> [TerminalProcess]? { table.values.filter { $0.name == name } }
        func processes(onTTY tty: String) -> [TerminalProcess]? { table.values.filter { $0.tty == tty }.sorted { $0.pid < $1.pid } }
        func children(of pid: Int) -> [TerminalProcess]? { table.values.filter { $0.parent == pid } }
        func socketOwners(in directory: String) -> [String: Int]? { [:] }
        func run(_ argv: [String]) -> (status: Int32, output: String) { (1, "") }
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        func record(_ call: String) { lock.withLock { _calls.append(call) } }
    }

    static let nightly = "dev.example.term-nightly"

    static let term = ScriptedTerminalRoute(
        name: "Example Term", apps: ["dev.example.term", nightly], front: "return front tty", body: "return true",
        placeScript: "return names",
        placesFrom: { answer, _, surface in
            PlaceLayer(labels: [.init(text: answer, level: .tab, container: "term#1", surface: surface, term: "tab")], containers: ["term#1"])
        })

    struct Source: AgentPlaceReading {
        let place: AgentPlace
        func read(_ queries: [AgentPlaceQuery]) async -> [String: AgentPlaceAnswer] {
            Dictionary(uniqueKeysWithValues: queries.map { ($0.id, AgentPlaceAnswer.found(place)) })
        }
    }

    static func surfaces() throws -> ResolvedSurfaces {
        var surfaces = AgentSurfaces.builtIn
        surfaces.terminals.append(term)
        return try surfaces.resolve()
    }

    static let facts = Facts()
        .add(10, parent: 1, "term", app: nightly)
        .add(30, parent: 10, tty: "/dev/ttys004", "claude")

    @Test @MainActor func theRuntimeReadsPlacesFromAnInjectedSourceBesideTheTerminals() async throws {
        let place = AgentPlace(surface: "Example Mux", labels: [.init(text: "builder", level: .pane, container: "mux#1")], containers: ["mux#1"])
        let reader = AgentRuntime.places(surfaces: try Self.surfaces(), sources: [Source(place: place)])
        let query = AgentPlaceQuery(id: "claude:a", agent: "claude", native: "a", pid: Int(Int32.max))
        #expect(await reader.read([query])[query.id] == .found(place))
    }

    @Test func anInjectedTerminalNamesThePlaceThroughItsOwnScriptAddressedToTheAppItRunsAs() async throws {
        let calls = Calls()
        let reader = TerminalPlaceReader(surfaces: try Self.surfaces(), facts: { Self.facts }, script: { app, pid, body in
            calls.record("\(app) \(pid) \(body)")
            return .value("Payments")
        })
        let query = AgentPlaceQuery(id: "claude:a", agent: "claude", native: "a", pid: 30)
        guard case .found(let place)? = await reader.read([query])[query.id] else {
            Issue.record("expected a place")
            return
        }
        #expect(calls.calls == ["\(Self.nightly) 10 return names"])
        #expect(place.labels.map(\.text) == ["Payments"])
        #expect(place.surface == "Example Term")
    }

    @Test @MainActor func anInjectedTerminalInFrontIsReadThroughItsOwnFrontScript() async throws {
        let calls = Calls()
        let front = AgentFront(
            surfaces: try Self.surfaces(), frontmost: { FrontApp(bundle: Self.nightly, pid: 10, name: "Term") },
            read: { app, pid, body, _ in
                calls.record("\(app) \(pid) \(body)")
                return .value("/dev/ttys004")
            },
            facts: { Self.facts }, confirming: false)
        #expect(await front.check(agent: 30) == .shown)
        #expect(calls.calls == ["\(Self.nightly) 10 return front tty"])
    }
}
