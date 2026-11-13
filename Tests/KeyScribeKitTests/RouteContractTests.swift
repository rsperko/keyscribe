import Foundation
import Testing
@testable import KeyScribeKit

struct RouteContractTests {
    typealias Facts = TerminalRoutesTests.Facts

    private struct Mux: PaneRoute {
        let name = "mux"
        let processName = "mux"
        let environmentKeys = ["MUX_PANE"]

        func open(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? {
            guard process.name == processName, process.arguments.contains("--server"),
                  let pane = inner.last?.environment["MUX_PANE"]
            else { return nil }
            return Opening([.layer(PaneLayer(name, commands: [PaneCommand(["mux", "focus", pane])]))], next: 20)
        }

        func isClient(_ process: TerminalProcess) -> Bool { process.name == processName && !process.arguments.contains("--server") }

        func front(client: TerminalProcess, tty: String, facts: TerminalFacts) -> FrontStep {
            let focused = facts.run(["mux", "focused", tty])
            return focused.status == 0 ? .tty(focused.output) : .unknown(.multiplexer(name))
        }
    }

    private static let ghostty = "com.mitchellh.ghostty"

    private static func facts() -> Facts {
        let facts = Facts()
            .add(10, parent: 1, ["ghostty"], app: ghostty)
            .add(20, parent: 10, tty: "/dev/ttys001", ["mux"])
            .add(40, parent: 1, ["mux", "--server"])
            .add(41, parent: 40, tty: "/dev/ttys008", ["claude"], environment: ["MUX_PANE": "7"])
            .add(42, parent: 40, tty: "/dev/ttys009", ["pi"], environment: ["MUX_PANE": "8"])
        facts.outputs[["mux", "focused", "/dev/ttys001"]] = "/dev/ttys008"
        return facts
    }

    @Test func aNewMultiplexerOpensThroughItsOwnRouteAndThenTheTerminalItsClientRunsIn() {
        let routes: [any Route] = [ScriptedTerminalRoute.ghostty, Mux()]
        #expect(TerminalRoutes.plan(agent: 41, facts: Self.facts(), routes: routes) == [
            .layer(PaneLayer("mux", commands: [PaneCommand(["mux", "focus", "7"])])),
        ] + ScriptedTerminalRoute.ghostty.open(pid: 10, ttys: ["/dev/ttys001"]))
    }

    @Test func aNewMultiplexerIsFollowedToTheViewItShowsInTheFrontTab() {
        let facts = Self.facts()
        let reading = FrontPanes.read(TerminalFront(app: Self.ghostty, tty: "/dev/ttys001"), facts: facts, panes: [Mux()])
        #expect(reading == .pane(FrontPane(app: Self.ghostty, tty: "/dev/ttys008", multiplexers: ["mux"])))
        #expect(reading.check(agent: 41, facts: facts) == .shown)
        #expect(reading.check(agent: 42, facts: facts) == .elsewhere)
        facts.outputs[["mux", "focused", "/dev/ttys001"]] = nil
        #expect(FrontPanes.read(TerminalFront(app: Self.ghostty, tty: "/dev/ttys001"), facts: facts, panes: [Mux()]) == .unknown(.multiplexer("mux")))
    }

    @Test func theBuiltInSurfacesResolve() throws {
        let resolved = try AgentSurfaces.builtIn.resolve()
        #expect(resolved.routes.count == AgentSurfaces.builtIn.terminals.count + AgentSurfaces.builtIn.multiplexers.count)
    }

    @Test func twoRoutesWithOneNameAreRejected() {
        var surfaces = AgentSurfaces.builtIn
        surfaces.multiplexers.append(Mux())
        surfaces.multiplexers.append(Mux())
        #expect(throws: AgentSurfaces.Conflict.name("mux")) { try surfaces.resolve() }
    }

    @Test func twoTerminalsClaimingOneAppAreRejected() {
        var surfaces = AgentSurfaces.builtIn
        surfaces.terminals.append(ScriptedTerminalRoute(name: "Other Ghostty", apps: [Self.ghostty], front: "", body: ""))
        #expect(throws: AgentSurfaces.Conflict.app(Self.ghostty)) { try surfaces.resolve() }
    }

    @Test func twoMultiplexersWatchingOneProcessAreRejected() {
        struct Copy: PaneRoute {
            let name = "copy"
            let processName = "mux"
            let environmentKeys: [String] = []
            func open(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? { nil }
            func isClient(_ process: TerminalProcess) -> Bool { false }
            func front(client: TerminalProcess, tty: String, facts: TerminalFacts) -> FrontStep { .unknown(.multiplexer(name)) }
        }
        var surfaces = AgentSurfaces.builtIn
        surfaces.multiplexers += [Mux(), Copy()]
        #expect(throws: AgentSurfaces.Conflict.processName("mux")) { try surfaces.resolve() }
    }

    private struct Focusing: PaneRoute {
        var name = "focusing"
        var processName = "focusing"
        var environmentKeys = ["FOCUS_PANE"]
        var focusDefinitions: [FocusDefinition]
        func open(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? { nil }
        func isClient(_ process: TerminalProcess) -> Bool { false }
        func front(client: TerminalProcess, tty: String, facts: TerminalFacts) -> FrontStep { .unknown(.multiplexer(name)) }
    }

    private static let paneFocus = FocusDefinition(id: "focusing", requiresEnv: ["FOCUS_PANE"], argv: ["/usr/local/bin/focusing", "show", "{FOCUS_PANE}"])

    @Test func theResolvedSurfacesCarryEveryRoutesFocusDefinitions() throws {
        var surfaces = AgentSurfaces.builtIn
        surfaces.multiplexers.append(Focusing(focusDefinitions: [Self.paneFocus]))
        let resolved = try surfaces.resolve()
        #expect(resolved.focusDefinitions.contains(Self.paneFocus))
        #expect(resolved.focusDefinitions.contains { $0.id == "cmux" })
    }

    @Test func whatAConnectorIsGivenChangesWhenAnyRouteChangesItsKeysOrFocusAndNotWithOrder() throws {
        let builtIn = ConnectorSurfaces(try AgentSurfaces.builtIn.resolve())
        #expect(builtIn.environmentKeys == builtIn.environmentKeys.sorted())
        #expect(builtIn.environmentKeys.contains("ZELLIJ_PANE_ID"))
        var focusing = AgentSurfaces.builtIn
        focusing.multiplexers.append(Focusing(focusDefinitions: [Self.paneFocus]))
        let added = ConnectorSurfaces(try focusing.resolve())
        #expect(added.fingerprint != builtIn.fingerprint)
        var changed = focusing
        changed.multiplexers[changed.multiplexers.count - 1] = Focusing(focusDefinitions: [
            FocusDefinition(id: "focusing", requiresEnv: ["FOCUS_PANE"], argv: ["/usr/local/bin/focusing", "raise", "{FOCUS_PANE}"]),
        ])
        #expect(ConnectorSurfaces(try changed.resolve()).fingerprint != added.fingerprint)
        var reordered = focusing
        reordered.multiplexers.insert(reordered.multiplexers.removeLast(), at: 0)
        #expect(ConnectorSurfaces(try reordered.resolve()) == added)
    }

    @Test(arguments: ["FOCUS PANE", "FOCUS-PANE", "1PANE", "", "PANE\")", "PANE;x"])
    func anEnvironmentKeyThatIsNotAPlainNameIsRejectedBeforeAnythingStarts(key: String) {
        var surfaces = AgentSurfaces.builtIn
        surfaces.multiplexers.append(Focusing(environmentKeys: [key], focusDefinitions: []))
        #expect(throws: AgentSurfaces.Conflict.environmentKey(key)) { try surfaces.resolve() }
    }

    @Test(arguments: [
        FocusDefinition(id: "cmux", requiresEnv: ["FOCUS_PANE"], argv: ["/usr/local/bin/focusing", "{FOCUS_PANE}"]),
        FocusDefinition(id: "loose", requiresEnv: ["FOCUS_PANE"], argv: ["focusing", "{FOCUS_PANE}"]),
        FocusDefinition(id: "unlisted", requiresEnv: ["FOCUS_PANE"], argv: ["/usr/local/bin/focusing", "{OTHER}"]),
        FocusDefinition(id: "foreign", requiresEnv: ["OTHER"], argv: ["/usr/local/bin/focusing", "{OTHER}"]),
        FocusDefinition(id: "empty", requiresEnv: [], argv: []),
    ])
    func aFocusDefinitionThatCannotRunSafelyIsRejectedBeforeAnythingStarts(definition: FocusDefinition) {
        var surfaces = AgentSurfaces.builtIn
        surfaces.multiplexers.append(Focusing(focusDefinitions: [definition]))
        #expect(throws: AgentSurfaces.Conflict.focusDefinition(definition.id)) { try surfaces.resolve() }
    }

    private static let twins = ScriptedTerminalRoute(
        name: "Twins", apps: ["dev.example.twins", "dev.example.twins-preview"],
        front: "return tty of front", body: "focus wanted", placeScript: "return names",
        placesFrom: { answer, _, surface in
            PlaceLayer(labels: [.init(text: answer, level: .tab, container: "twins#1", surface: surface, term: "tab")], containers: ["twins#1"])
        })

    @Test func aTerminalWithSeveralAppsAddressesTheOneItsProcessRunsAs() throws {
        var surfaces = AgentSurfaces.builtIn
        surfaces.terminals.append(Self.twins)
        let resolved = try surfaces.resolve()
        let preview = "dev.example.twins-preview"
        #expect(resolved.terminal(preview)?.name == "Twins")
        let facts = Facts()
            .add(10, parent: 1, ["twins"], app: preview)
            .add(11, parent: 10, tty: "/dev/ttys001", ["claude"])

        let plan = TerminalRoutes.plan(agent: 11, facts: facts, routes: resolved.routes)
        #expect(plan == Self.twins.open(app: preview, pid: 10, ttys: ["/dev/ttys001"]))
        #expect(TerminalRoutes.layers(of: plan).app == preview)

        let walk = TerminalPlaces.walk(agent: 11, facts: facts, routes: resolved.routes)
        #expect(walk?.host == TerminalHost(route: "Twins", app: preview, pid: 10, ttys: ["/dev/ttys001"]))

        let twins = try #require(resolved.terminal(preview))
        let reading = FrontPanes.read(answer: "/dev/ttys001", from: twins, app: preview, appPid: 10, facts: facts, panes: resolved.multiplexers)
        #expect(reading == .pane(FrontPane(app: preview, tty: "/dev/ttys001", multiplexers: [])))
        #expect(reading.check(agent: 11, facts: facts, surfaces: resolved) == .shown)
    }

    @Test func aMultiplexerAppendedBeforeResolvingTakesPartInOpenFrontPlacesAndTheEnvironmentFilter() throws {
        var surfaces = AgentSurfaces.builtIn
        surfaces.multiplexers.append(Mux())
        let resolved = try surfaces.resolve()
        let facts = Self.facts()

        #expect(resolved.environmentKeys.contains("MUX_PANE"))
        #expect(TerminalRoutes.plan(agent: 41, facts: facts, routes: resolved.routes).first
            == .layer(PaneLayer("mux", commands: [PaneCommand(["mux", "focus", "7"])])))

        let reading = FrontPanes.read(TerminalFront(app: Self.ghostty, tty: "/dev/ttys001"), facts: facts, panes: resolved.multiplexers)
        #expect(reading.check(agent: 41, facts: facts, surfaces: resolved) == .shown)

        let reported = Facts().add(50, parent: 1, ["claude"])
        let kept = reported.reporting(["MUX_PANE": "9", "SECRET": "x"], for: 50, keeping: resolved.environmentKeys)
        #expect(kept.process(50)?.environment == ["MUX_PANE": "9"])

        let walk = TerminalPlaces.walk(agent: 41, facts: facts, routes: resolved.routes)
        #expect(walk?.host == TerminalHost(route: "Ghostty", app: Self.ghostty, pid: 10, ttys: ["/dev/ttys001"]))
    }
}
