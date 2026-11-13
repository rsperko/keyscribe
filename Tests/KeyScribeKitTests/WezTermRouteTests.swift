import Foundation
import Testing
@testable import KeyScribeKit

struct WezTermRouteTests {
    typealias Facts = TerminalRoutesTests.Facts

    private static let app = "com.github.wez.wezterm"
    private static let gui = "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui"
    private static let socket = "/Users/me/.local/share/wezterm/gui-sock-10"
    private static let cli = ["/usr/bin/env", "WEZTERM_UNIX_SOCKET=\(socket)", "/Applications/WezTerm.app/Contents/MacOS/wezterm", "cli", "--no-auto-start"]

    private static let clients = """
        [{"username":"me","hostname":"Mac","pid":10,"connection_elapsed":{"secs":9,"nanos":0},\
        "idle_time":{"secs":9,"nanos":0},"workspace":"default","focused_pane_id":1}]
        """

    private static let panes = """
        [{"window_id":0,"tab_id":0,"pane_id":0,"workspace":"default","title":"zsh","is_active":true,"tty_name":"/dev/ttys035"},
         {"window_id":0,"tab_id":1,"pane_id":1,"workspace":"default","title":"claude","is_active":true,"tty_name":"/dev/ttys036"}]
        """

    private static func facts() -> Facts {
        let env = { (pane: String) in ["WEZTERM_PANE": pane, "WEZTERM_UNIX_SOCKET": socket] }
        let facts = Facts()
            .add(10, parent: 1, [gui], app: app)
            .add(20, parent: 10, tty: "/dev/ttys035", ["-zsh"], environment: env("0"))
            .add(21, parent: 10, tty: "/dev/ttys036", ["-zsh"], environment: env("1"))
            .add(30, parent: 21, tty: "/dev/ttys036", ["claude"], environment: env("1"))
            .add(31, parent: 20, tty: "/dev/ttys035", ["claude"], environment: env("0"))
        facts.listening[10] = [socket]
        facts.outputs[cli + ["list-clients", "--format", "json"]] = clients
        facts.outputs[cli + ["list", "--format", "json"]] = panes
        return facts
    }

    @Test func openActivatesTheAgentsPaneThroughItsOwnGUIWithoutStartingAServer() throws {
        let resolved = try AgentSurfaces.builtIn.resolve()
        #expect(TerminalRoutes.plan(agent: 30, facts: Self.facts(), routes: resolved.routes) == [
            .select(.command(PaneCommand(
                Self.cli + ["activate-pane", "--pane-id", "1"],
                until: FocusWalk(
                    check: Self.cli + ["list-clients", "--format", "json"],
                    listing: .json(rowsWhere: ["pid": "10"], column: "focused_pane_id"), value: "1", steps: 1)))),
            .activate(app: Self.app, pid: 10),
        ])
        #expect(resolved.terminal(Self.app)?.noun == "pane")
    }

    private static func walk() throws -> FocusWalk {
        let plan = TerminalRoutes.plan(agent: 30, facts: Self.facts(), routes: try AgentSurfaces.builtIn.resolve().routes)
        let command = try #require(plan.first.flatMap { action -> PaneCommand? in
            if case .select(.command(let command)) = action { return command }
            return nil
        })
        return try #require(command.until)
    }

    private static func client(pid: Int, workspace: String = "default", focus: String) -> String {
        "{\"username\":\"me\",\"hostname\":\"Mac\",\"pid\":\(pid),\"workspace\":\"\(workspace)\",\"focused_pane_id\":\(focus)}"
    }

    @Test func thePaneIsConfirmedOnlyByTheFocusItsOwnGUIReports() throws {
        let walk = try Self.walk()
        #expect(walk.reached((0, "[\(Self.client(pid: 10, focus: "1"))]")) == true)
        #expect(walk.reached((0, "[\(Self.client(pid: 10, focus: "5"))]")) == false)
        #expect(walk.reached((0, "[\(Self.client(pid: 10, workspace: "project 1", focus: "5"))]")) == false)
        #expect(walk.reached((0, "[\(Self.client(pid: 10, focus: "5")),\(Self.client(pid: 77, focus: "1"))]")) == false)
        #expect(walk.reached((0, "[\(Self.client(pid: 77, focus: "1"))]")) == nil)
        #expect(walk.reached((0, "[\(Self.client(pid: 10, focus: "null"))]")) == false)
        #expect(walk.reached((1, "")) == nil)
        #expect(walk.reached((0, "USER HOST PID\nme Mac 10")) == nil)
    }

    @Test func aGUIRunAsARelativePathIsNeitherFocusedNorReadThroughIt() throws {
        let resolved = try AgentSurfaces.builtIn.resolve()
        let facts = Self.facts()
        facts.add(10, parent: 1, ["wezterm-gui"], executable: "wezterm-gui", app: Self.app)
        #expect(TerminalRoutes.plan(agent: 30, facts: facts, routes: resolved.routes) == [.activate(app: Self.app, pid: 10)])
        #expect(resolved.terminal(Self.app)?.readFront(appPid: 10, facts: facts, reported: []) == .unknown(.processesUnreadable))
        #expect(facts.ran.isEmpty)
    }

    @Test func theFrontIsTheTTYOfThePaneTheGUIReportsFocused() throws {
        let resolved = try AgentSurfaces.builtIn.resolve()
        let facts = Self.facts()
        let terminal = try #require(resolved.terminal(Self.app))
        let reading = FrontPanes.read(try #require(terminal.readFront(appPid: 10, facts: facts, reported: [])), app: Self.app, facts: facts, panes: resolved.multiplexers)
        #expect(reading == .pane(FrontPane(app: Self.app, tty: "/dev/ttys036", multiplexers: [])))
        #expect(reading.check(agent: 30, facts: facts, surfaces: resolved) == .shown)
        #expect(reading.check(agent: 31, facts: facts, surfaces: resolved) == .elsewhere)
    }

    @Test func anotherClientWithNoFocusNeverHidesTheGUIsOwn() throws {
        let resolved = try AgentSurfaces.builtIn.resolve()
        let facts = Self.facts()
        facts.outputs[Self.cli + ["list-clients", "--format", "json"]] = "[\(Self.client(pid: 77, focus: "null")),\(Self.client(pid: 10, focus: "1"))]"
        let front = try #require(resolved.terminal(Self.app)?.readFront(appPid: 10, facts: facts, reported: []))
        #expect(front == .tty("/dev/ttys036"))
    }

    @Test func aFrontTheCLICannotAnswerIsUnknown() throws {
        let terminal = try #require(try AgentSurfaces.builtIn.resolve().terminal(Self.app))
        let silent = Self.facts()
        silent.outputs = [:]
        #expect(terminal.readFront(appPid: 10, facts: silent, reported: []) == .unknown(.unreadable("WezTerm")))
        let otherGUI = Self.facts()
        otherGUI.outputs[Self.cli + ["list-clients", "--format", "json"]] = Self.clients.replacingOccurrences(of: "\"pid\":10", with: "\"pid\":11")
        #expect(terminal.readFront(appPid: 10, facts: otherGUI, reported: []) == .unknown(.unreported("WezTerm")))
        let idle = Self.facts()
        idle.outputs[Self.cli + ["list-clients", "--format", "json"]] = "[\(Self.client(pid: 10, focus: "null"))]"
        #expect(terminal.readFront(appPid: 10, facts: idle, reported: []) == .unknown(.unreported("WezTerm")))
        let gone = Self.facts()
        gone.outputs[Self.cli + ["list", "--format", "json"]] = "[]"
        #expect(terminal.readFront(appPid: 10, facts: gone, reported: []) == .unknown(.unreported("WezTerm")))
    }
}
