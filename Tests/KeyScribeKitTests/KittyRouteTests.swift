import Foundation
import Testing
@testable import KeyScribeKit

struct KittyRouteTests {
    typealias Facts = TerminalRoutesTests.Facts

    private static let app = "net.kovidgoyal.kitty"
    private static let socket = "/tmp/kitty-10"
    private static let remote = ["/Applications/kitty.app/Contents/MacOS/kitten", "@", "--to", "unix:/tmp/kitty-10"]

    private static func focused(_ window: Int, pid: Int, focused: Bool = true) -> String {
        """
        [{"id":1,"is_active":true,"is_focused":\(focused),"tabs":[{"id":1,"is_active":true,"is_focused":\(focused),"windows":[\
        {"id":\(window),"pid":\(pid),"is_active":true,"is_focused":\(focused),"title":"claude","env":{"KITTY_WINDOW_ID":"\(window)"},\
        "foreground_processes":[{"pid":\(pid),"cmdline":["claude"]}]}]}]}]
        """
    }

    private static func facts(remoteControl: Bool = true) -> Facts {
        let env = { (window: String) in
            remoteControl ? ["KITTY_WINDOW_ID": window, "KITTY_LISTEN_ON": "unix:\(socket)"] : ["KITTY_WINDOW_ID": window]
        }
        let facts = Facts()
            .add(10, parent: 1, ["/Applications/kitty.app/Contents/MacOS/kitty"], app: app)
            .add(20, parent: 10, tty: "/dev/ttys035", ["/usr/bin/login"])
            .add(21, parent: 10, tty: "/dev/ttys036", ["/usr/bin/login"])
            .add(30, parent: 20, tty: "/dev/ttys035", ["claude"], environment: env("1"))
            .add(31, parent: 21, tty: "/dev/ttys036", ["pi"], environment: env("2"))
        if remoteControl { facts.listening[10] = [socket] }
        facts.outputs[remote + ["ls", "--match", "state:focused"]] = focused(1, pid: 20)
        return facts
    }

    @Test func withRemoteControlOnOpenFocusesTheAgentsWindowThroughTheSocketKittyListensOn() throws {
        let resolved = try AgentSurfaces.builtIn.resolve()
        #expect(TerminalRoutes.plan(agent: 31, facts: Self.facts(), routes: resolved.routes) == [
            .select(.command(PaneCommand(Self.remote + ["focus-window", "--match", "id:2"]))),
            .activate(app: Self.app, pid: 10),
        ])
        #expect(resolved.environmentKeys.isSuperset(of: ["KITTY_WINDOW_ID", "KITTY_LISTEN_ON"]))
    }

    @Test func withRemoteControlOffKittyOnlyComesForward() throws {
        let facts = Self.facts(remoteControl: false)
        let resolved = try AgentSurfaces.builtIn.resolve()
        #expect(TerminalRoutes.plan(agent: 31, facts: facts, routes: resolved.routes) == [.activate(app: Self.app, pid: 10)])
        #expect(resolved.terminal(Self.app)?.readFront(appPid: 10, facts: facts, reported: []) == .unknown(.unreported("kitty")))
        #expect(facts.ran.isEmpty)
    }

    @Test func theFrontIsTheTTYOfTheWindowKittyReportsFocused() throws {
        let resolved = try AgentSurfaces.builtIn.resolve()
        let facts = Self.facts()
        let kitty = try #require(resolved.terminal(Self.app))
        let reading = FrontPanes.read(try #require(kitty.readFront(appPid: 10, facts: facts, reported: [])), app: Self.app, facts: facts, panes: resolved.multiplexers)
        #expect(reading == .pane(FrontPane(app: Self.app, tty: "/dev/ttys035", multiplexers: [])))
        #expect(reading.check(agent: 30, facts: facts, surfaces: resolved) == .shown)
        #expect(reading.check(agent: 31, facts: facts, surfaces: resolved) == .elsewhere)
    }

    @Test func aSingleInstanceKittyIsReadThroughTheRemoteControlSocketItsProcessesOrConversationsCarry() throws {
        let kitty = try #require(try AgentSurfaces.builtIn.resolve().terminal(Self.app))
        let facts = Self.facts()
        facts.listening[10] = [Self.socket, "/var/folders/qt/xx/C/kitty-ipc-501"]
        #expect(kitty.readFront(appPid: 10, facts: facts, reported: []) == .tty("/dev/ttys035"))
        let hidden = Self.facts()
        hidden.listening[10] = [Self.socket, "/var/folders/qt/xx/C/kitty-ipc-501"]
        hidden.table[30]?.environment = [:]
        hidden.table[31]?.environment = [:]
        #expect(kitty.readFront(appPid: 10, facts: hidden, reported: []) == .unknown(.ambiguous))
        #expect(kitty.readFront(appPid: 10, facts: hidden, reported: [["KITTY_LISTEN_ON": "unix:\(Self.socket)"]]) == .tty("/dev/ttys035"))
        #expect(hidden.ran == [Self.remote + ["ls", "--match", "state:focused"]])
    }

    @Test func aWindowKittyDoesNotReportFocusedOrAnAnswerItCannotParseIsUnknown() throws {
        let kitty = try #require(try AgentSurfaces.builtIn.resolve().terminal(Self.app))
        let unfocused = Self.facts()
        unfocused.outputs[Self.remote + ["ls", "--match", "state:focused"]] = Self.focused(1, pid: 20, focused: false)
        #expect(kitty.readFront(appPid: 10, facts: unfocused, reported: []) == .unknown(.unreported("kitty")))
        let refused = Self.facts()
        refused.outputs = [:]
        #expect(kitty.readFront(appPid: 10, facts: refused, reported: []) == .unknown(.unreadable("kitty")))
    }
}
