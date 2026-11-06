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

    @Test func everyRouteHasItsOwnNameAndEveryTerminalItsOwnApp() {
        #expect(Set(TerminalRoutes.routes.map(\.name)).count == TerminalRoutes.routes.count)
        #expect(Set(TerminalRoutes.terminalRoutes.map(\.app)).count == TerminalRoutes.terminalRoutes.count)
    }
}
