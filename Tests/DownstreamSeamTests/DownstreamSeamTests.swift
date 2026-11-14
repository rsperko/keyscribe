import Foundation
import KeyScribeApp
import KeyScribeKit
import Testing

struct DownstreamSeamTests {
    struct Mux: PaneRoute {
        let name = "Downstream Mux"
        let processName = "dmux"
        let environmentKeys = ["DMUX_PANE"]

        func open(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? {
            guard process.name == processName, process.tty == nil,
                  let pane = TerminalRoutes.nearest("DMUX_PANE", in: inner)?.environment["DMUX_PANE"]
            else { return nil }
            let clients = facts.processes(named: processName)?.filter(isClient).map(\.pid) ?? []
            guard let client = TerminalRoutes.steadiest(clients, preferring: nil) else { return Opening([.layer(.unresolved(name))]) }
            return Opening([.layer(PaneLayer(name, commands: [PaneCommand(["dmux", "focus", pane])]))], next: client)
        }

        func isClient(_ process: TerminalProcess) -> Bool { process.name == processName && process.tty != nil }

        func front(client: TerminalProcess, tty: String, facts: TerminalFacts) -> FrontStep {
            let rows = TerminalRoutes.rows(facts.run(["dmux", "focused", tty]))
            guard let inner = rows.first?.first else { return .unknown(.multiplexer(name)) }
            return .tty(inner)
        }
    }

    static let term = ScriptedTerminalRoute(
        name: "Downstream Term", apps: ["dev.example.term", "dev.example.term-nightly"], helperPrefix: nil,
        front: "return tty of front", body: "return true", placeScript: "return names",
        placesFrom: { _, _, _ in PlaceLayer() })

    struct Places: AgentPlaceReading {
        func read(_ queries: [AgentPlaceQuery]) async -> [String: AgentPlaceAnswer] {
            Dictionary(uniqueKeysWithValues: queries.map { ($0.id, AgentPlaceAnswer.absent) })
        }
    }

    final class Facts: TerminalFacts, @unchecked Sendable {
        var table: [Int: TerminalProcess] = [:]
        var outputs: [[String]: String] = [:]

        func add(_ pid: Int, parent: Int, tty: String? = nil, _ name: String, environment: [String: String] = [:], app: String? = nil) -> Facts {
            table[pid] = TerminalProcess(
                pid: pid, parent: parent, tty: tty, arguments: [name], environment: environment, executable: name, app: app)
            return self
        }

        func process(_ pid: Int) -> TerminalProcess? { table[pid] }
        func processes(named name: String) -> [TerminalProcess]? { table.values.filter { $0.name == name }.sorted { $0.pid < $1.pid } }
        func processes(onTTY tty: String) -> [TerminalProcess]? { table.values.filter { $0.tty == tty }.sorted { $0.pid < $1.pid } }
        func children(of pid: Int) -> [TerminalProcess]? { table.values.filter { $0.parent == pid } }
        func socketOwners(in directory: String) -> [String: Int]? { [:] }
        func run(_ argv: [String]) -> (status: Int32, output: String) { outputs[argv].map { (0, $0) } ?? (1, "") }
    }

    static func integrations() -> CodingAgentIntegrations {
        var integrations = CodingAgentIntegrations.builtIn
        integrations.surfaces.terminals.append(term)
        integrations.surfaces.multiplexers.append(Mux())
        integrations.placeSources.append { Places() }
        return integrations
    }

    @Test func aDownstreamTerminalAndMultiplexerOpenTheAgentThroughEveryLayer() throws {
        let resolved = try Self.integrations().surfaces.resolve()
        let facts = Facts()
            .add(10, parent: 1, "term", app: "dev.example.term-nightly")
            .add(20, parent: 10, tty: "/dev/ttys001", "dmux")
            .add(40, parent: 1, "dmux")
            .add(41, parent: 40, tty: "/dev/ttys008", "claude", environment: ["DMUX_PANE": "7"])
        facts.outputs[["dmux", "focused", "/dev/ttys001"]] = "/dev/ttys008"

        #expect(resolved.environmentKeys.contains("DMUX_PANE"))
        #expect(TerminalRoutes.plan(agent: 41, facts: facts, routes: resolved.routes) == [
            .layer(PaneLayer("Downstream Mux", commands: [PaneCommand(["dmux", "focus", "7"])])),
        ] + Self.term.open(app: "dev.example.term-nightly", pid: 10, ttys: ["/dev/ttys001"]))

        let terminal = try #require(resolved.terminal("dev.example.term-nightly"))
        let reading = FrontPanes.read(
            answer: "/dev/ttys001", from: terminal, app: "dev.example.term-nightly", appPid: 10, facts: facts, panes: resolved.multiplexers)
        #expect(reading.check(agent: 41, facts: facts, surfaces: resolved) == .shown)

        let walk = TerminalPlaces.walk(agent: 41, facts: facts, routes: resolved.routes)
        #expect(walk?.host?.app == "dev.example.term-nightly")
    }

    @Test func theDownstreamRoutesPassTheConformanceCheck() {
        #expect(RouteConformance.problems(Self.integrations().surfaces) == [])
    }

    @Test @MainActor func theAppAcceptsTheIntegrationsAndTheDevCLIAcceptsTheSameValue() {
        let integrations = Self.integrations()
        _ = AppDelegate(codingAgents: integrations)
        let handle: (CodingAgentIntegrations) -> Void = DevCLI.handleFlags(codingAgents:)
        _ = handle
    }

    @MainActor final class Host: AgentHost {
        var isEnabled = false

        func scan() async -> AgentHostScan {
            .found([AgentSession(
                agent: "downstream", id: "t1", pid: nil, cwd: "/src", state: .idle,
                host: AgentHostLocation(host: "downstream", instance: "/run/d.sock", native: "t1"))])
        }

        func deliver(_ text: String, request: String, to location: AgentHostLocation) async -> AgentHostDelivery { .queued }
    }

    @Test @MainActor func aDownstreamHostIsAddedThroughThePublicSurfaceAlone() async throws {
        var integrations = Self.integrations()
        integrations.hosts.append(AgentHostIntegration(
            kind: AgentKind(id: "downstream", displayName: "Downstream Host", connectorName: "Downstream plugin"), make: { Host() }))
        _ = AppDelegate(codingAgents: integrations)
        #expect(throws: Never.self) { try integrations.resolve() }
        let host = integrations.hosts[0].make()
        #expect(await host.open(AgentHostLocation(host: "downstream", instance: "/run/d.sock", native: "t1")) == .unsupported)
        #expect(try await HostCLI.run(["/usr/bin/true"], subcommand: "true").status == 0)
    }

    @Test func aConflictingDownstreamRouteIsRejectedBeforeAnythingStarts() {
        var integrations = Self.integrations()
        integrations.surfaces.terminals.append(Self.term)
        #expect(throws: AgentSurfaces.Conflict.name("Downstream Term")) { try integrations.surfaces.resolve() }
    }
}
