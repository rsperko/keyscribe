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

    struct Mux: PaneRoute {
        let name = "Example Mux"
        let processName = "xmux"
        let environmentKeys = ["XMUX_PANE"]

        func open(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? {
            guard process.name == processName, process.tty == nil,
                  let pane = TerminalRoutes.nearest("XMUX_PANE", in: inner)?.environment["XMUX_PANE"]
            else { return nil }
            let client = facts.processes(named: processName)?.first(where: isClient)?.pid
            return Opening([.layer(PaneLayer(name, commands: [PaneCommand(["xmux", "focus", pane])]))], next: client)
        }

        func isClient(_ process: TerminalProcess) -> Bool { process.name == processName && process.tty != nil }
        func front(client: TerminalProcess, tty: String, facts: TerminalFacts) -> FrontStep { .unknown(.multiplexer(name)) }
    }

    static func surfaces() throws -> ResolvedSurfaces {
        var surfaces = AgentSurfaces.builtIn
        surfaces.terminals.append(term)
        surfaces.multiplexers.append(Mux())
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

    @Test @MainActor func openingAnAgentInAnInjectedMultiplexerRunsItsStepThenTheInjectedTerminalsScript() async throws {
        let facts = Facts()
            .add(10, parent: 1, "term", app: Self.nightly)
            .add(20, parent: 10, tty: "/dev/ttys001", "xmux")
            .add(40, parent: 1, "xmux")
            .add(41, parent: 40, tty: "/dev/ttys008", "claude")
        let calls = Calls()
        var focus = AgentTerminalFocus(plan: AgentTerminalFocus.plan(try Self.surfaces(), facts: { facts }))
        focus.run = { argv in
            calls.record(argv.joined(separator: " "))
            return (0, "")
        }
        focus.script = { app, pid, body, _, _ in
            calls.record("script \(app) \(pid) \(body.contains("/dev/ttys001"))")
            return .selected
        }
        focus.running = { app, near in (near, app) }
        focus.activate = { _ in "Term" }
        let result = await focus.focus(session: "s1", pid: 41, environment: ["XMUX_PANE": "7", "UNRELATED": "x"], asking: { _ in })
        #expect(result == .exact)
        #expect(calls.calls == ["xmux focus 7", "script \(Self.nightly) 10 true"])
    }

    struct Answering: AgentPlaceReading {
        let answer: AgentPlaceAnswer?
        func read(_ queries: [AgentPlaceQuery]) async -> [String: AgentPlaceAnswer] {
            Dictionary(uniqueKeysWithValues: queries.compactMap { query in answer.map { (query.id, $0) } })
        }
    }

    @Test @MainActor func theProbeReadsPlacesThroughTheSameReadersTheAppUses() async throws {
        let place = AgentPlace(
            surface: "Example Mux", labels: [.init(text: "builder", level: .pane, container: "mux#1"), .init(text: "Payments", level: .tab, container: "mux#t")],
            containers: ["mux#1", "mux#t"])
        let reader = AgentRuntime.places(surfaces: try Self.surfaces(), sources: [Source(place: place)])
        #expect(await PlaceProbe.lines(pid: Int(Int32.max), agent: "claude", session: "a", reader: reader)
            == ["read surface=Example Mux labels=pane:builder,tab:Payments containers=mux#1,mux#t"])
    }

    @Test(arguments: [(AgentPlaceAnswer.absent, "read=absent"), (.unknown, "read=unknown"), (nil, "read=unknown")] as [(AgentPlaceAnswer?, String)])
    func theProbeSaysWhenNoReaderNamedThePlace(answer: AgentPlaceAnswer?, line: String) async {
        #expect(await PlaceProbe.lines(pid: 30, agent: "claude", session: "a", reader: Answering(answer: answer)) == [line])
    }

    @Test @MainActor func settingsAndTheRuntimeBuildTheirAgentsFromTheSameList() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let setups = ConnectorSetupRegistry(directory: dir)
        let processes = AgentProcessTable(list: { _ in [] })
        let surfaces = ConnectorSurfaces(environmentKeys: [])
        let builtIn = CodingAgentIntegrations.builtIn
        #expect(builtIn.discoveries(setups: setups, processes: processes).map(\.kind.id) == ["claude", "pi"])
        #expect(builtIn.connectors(agentsDir: dir, pluginName: "p", surfaces: surfaces).map(\.kind.id) == ["claude", "pi"])
        let fake = AgentKind(id: "fake", displayName: "Fake", connectorName: "Fake connector")
        var extended = builtIn
        extended.agents.append(AgentIntegration(
            kind: fake, discovery: { _, _ in AgentHubTests.FakeDiscovery(kind: fake) },
            connector: { AgentIntegration.pi.connector($0, $1, $2) }))
        #expect(extended.discoveries(setups: setups, processes: processes).map(\.kind.id) == ["claude", "pi", "fake"])
        #expect(extended.connectors(agentsDir: dir, pluginName: "p", surfaces: surfaces).count == 3)
    }

    @Test @MainActor func aHostWhoseIdAnotherAgentOrHostUsesIsRejectedBeforeAnythingStarts() throws {
        var integrations = CodingAgentIntegrations.builtIn
        _ = try integrations.resolve()
        integrations.hosts.append(AgentHostIntegration(kind: AgentHostTests.kind, make: { AgentHostTests.FakeHost() }))
        _ = try integrations.resolve()
        var twice = integrations
        twice.hosts.append(AgentHostIntegration(kind: AgentHostTests.kind, make: { AgentHostTests.FakeHost() }))
        #expect(throws: AgentSurfaces.Conflict.kind("example")) { try twice.resolve() }
        var asAgent = integrations
        asAgent.hosts.append(AgentHostIntegration(kind: .claude, make: { AgentHostTests.FakeHost() }))
        #expect(throws: AgentSurfaces.Conflict.kind("claude")) { try asAgent.resolve() }
        var separator = integrations
        separator.hosts[0].kind = AgentKind(id: "ex:ample", displayName: "Example", connectorName: "")
        #expect(throws: AgentSurfaces.Conflict.kind("ex:ample")) { try separator.resolve() }
    }
}
