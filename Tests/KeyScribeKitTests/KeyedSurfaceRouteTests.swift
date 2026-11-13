import Foundation
import Testing
@testable import KeyScribeKit

struct KeyedSurfaceRouteTests {
    typealias Facts = TerminalRoutesTests.Facts

    private static let app = "dev.example.keyed"
    private static let socket = "/Users/me/.local/share/keyed/sock-10"

    private static let route = KeyedSurfaceRoute(
        name: "Keyed", apps: [app], key: "KEYED_PANE", socket: "KEYED_SOCKET", noun: "pane",
        focus: .command { terminal, pane, socket in
            guard pane.allSatisfy(\.isNumber) else { return nil }
            return PaneCommand(["/usr/bin/env", "KEYED_SOCKET=\(socket ?? "")", terminal.executable, "focus", pane])
        },
        front: { terminal, socket, facts in
            let answer = facts.run([terminal.executable, "front", socket ?? ""])
            return answer.status == 0 ? .tty(answer.output) : .unknown(.unreadable("Keyed"))
        })

    private static func facts(pane: String = "3", socket: String = socket, owner: Int = 10) -> Facts {
        let facts = Facts()
            .add(10, parent: 1, ["keyed-gui"], executable: "/Applications/Keyed.app/keyed", app: app)
            .add(20, parent: 10, tty: "/dev/ttys020", ["-zsh"], environment: ["KEYED_PANE": pane, "KEYED_SOCKET": socket])
            .add(30, parent: 20, tty: "/dev/ttys020", ["claude"], environment: ["KEYED_PANE": pane, "KEYED_SOCKET": socket])
        facts.listening[owner] = [Self.socket]
        return facts
    }

    @Test func theRouteListsItsKeyAndItsSocketForEveryEnvironmentFilter() throws {
        #expect(Self.route.environmentKeys == ["KEYED_PANE", "KEYED_SOCKET"])
        var surfaces = AgentSurfaces.builtIn
        surfaces.terminals.append(Self.route)
        #expect(try surfaces.resolve().environmentKeys.isSuperset(of: ["KEYED_PANE", "KEYED_SOCKET"]))
    }

    @Test func aCommandFocusRunsAgainstTheSocketTheTerminalItselfOwns() {
        #expect(TerminalRoutes.plan(agent: 30, facts: Self.facts(), routes: [Self.route]) == [
            .select(.command(PaneCommand(["/usr/bin/env", "KEYED_SOCKET=\(Self.socket)", "/Applications/Keyed.app/keyed", "focus", "3"]))),
            .activate(app: Self.app, pid: 10),
        ])
    }

    @Test func aSocketAnotherProcessOwnsOrNoOneOwnsOnlyBringsTheTerminalForward() {
        let activate: [OpenAction] = [.activate(app: Self.app, pid: 10)]
        #expect(TerminalRoutes.plan(agent: 30, facts: Self.facts(owner: 99), routes: [Self.route]) == activate)
        #expect(TerminalRoutes.plan(agent: 30, facts: Self.facts(socket: "/elsewhere/sock"), routes: [Self.route]) == activate)
    }

    @Test(arguments: ["-3", "", "--all", "3 4"])
    func aValueThatCouldReadAsAnOptionOrThatTheRouteRejectsOnlyBringsTheTerminalForward(pane: String) {
        #expect(TerminalRoutes.plan(agent: 30, facts: Self.facts(pane: pane), routes: [Self.route]) == [.activate(app: Self.app, pid: 10)])
    }

    @Test func withoutTheKeyTheTerminalOnlyComesForward() {
        let facts = Facts()
            .add(10, parent: 1, ["keyed-gui"], app: Self.app)
            .add(30, parent: 10, tty: "/dev/ttys020", ["claude"])
        #expect(TerminalRoutes.plan(agent: 30, facts: facts, routes: [Self.route]) == [.activate(app: Self.app, pid: 10)])
    }

    @Test func aURLFocusOpensTheValueClosestToTheTerminalThatCarriesItsPrefix() {
        let route = KeyedSurfaceRoute(name: "Linked", apps: [Self.app], key: "LINK", focus: .url(prefix: "linked://"))
        let facts = Facts()
            .add(10, parent: 1, ["linked"], app: Self.app)
            .add(20, parent: 10, tty: "/dev/ttys020", ["-zsh"], environment: ["LINK": "other://x"])
            .add(25, parent: 20, tty: "/dev/ttys020", ["sh"], environment: ["LINK": "linked://outer"])
            .add(30, parent: 25, tty: "/dev/ttys020", ["claude"], environment: ["LINK": "linked://inner"])
        #expect(TerminalRoutes.plan(agent: 30, facts: facts, routes: [route]) == [.select(.url("linked://outer")), .activate(app: Self.app, pid: 10)])
        #expect(route.noun == "tab")
    }

    @Test func theFrontIsReadThroughTheSocketTheTerminalsOwnChildrenCarry() {
        let facts = Self.facts()
        facts.outputs[["/Applications/Keyed.app/keyed", "front", Self.socket]] = "/dev/ttys020"
        let reading = FrontPanes.read(Self.route.readFront(appPid: 10, facts: facts, reported: [])!, app: Self.app, facts: facts, panes: [])
        #expect(reading == .pane(FrontPane(app: Self.app, tty: "/dev/ttys020", multiplexers: [])))
    }

    @Test func aFrontWithNoSocketTheTerminalListensOnOrSeveralIsUnknownAndRunsNothing() {
        let unowned = Self.facts(owner: 99)
        #expect(Self.route.readFront(appPid: 10, facts: unowned, reported: []) == .unknown(.unreported("Keyed")))
        let several = Self.facts()
        several.listening[10] = ["/Users/me/.local/share/keyed/sock-11", "/Users/me/.local/share/keyed/sock-12"]
        #expect(Self.route.readFront(appPid: 10, facts: several, reported: []) == .unknown(.ambiguous))
        #expect(unowned.ran.isEmpty && several.ran.isEmpty)
        let unreadable = Self.facts()
        unreadable.socketsUnreadable = true
        #expect(Self.route.readFront(appPid: 10, facts: unreadable, reported: []) == .unknown(.processesUnreadable))
    }

    @Test func aSocketWrittenWithItsSchemeIsTheSameSocket() {
        let facts = Self.facts(socket: "unix:\(Self.socket)")
        #expect(TerminalRoutes.plan(agent: 30, facts: facts, routes: [Self.route]).first
            == .select(.command(PaneCommand(["/usr/bin/env", "KEYED_SOCKET=\(Self.socket)", "/Applications/Keyed.app/keyed", "focus", "3"]))))
    }

    @Test func aTerminalListeningOnSeveralSocketsIsReadThroughTheOneItsOwnProcessesCarryBelowAHiddenLogin() {
        let facts = Facts()
            .add(10, parent: 1, ["keyed-gui"], executable: "/Applications/Keyed.app/keyed", app: Self.app)
            .add(20, parent: 10, tty: "/dev/ttys020", ["/usr/bin/login"])
            .add(25, parent: 20, tty: "/dev/ttys020", ["-zsh"])
            .add(30, parent: 25, tty: "/dev/ttys020", ["claude"], environment: ["KEYED_PANE": "3", "KEYED_SOCKET": "unix:\(Self.socket)"])
        facts.listening[10] = [Self.socket, "/var/folders/xx/C/keyed-ipc-501"]
        facts.outputs[["/Applications/Keyed.app/keyed", "front", Self.socket]] = "/dev/ttys020"
        #expect(Self.route.readFront(appPid: 10, facts: facts, reported: []) == .tty("/dev/ttys020"))
    }

    @Test func aTerminalListeningOnSeveralSocketsWhoseProcessesCarryNoneIsReadThroughTheOneItsConversationsReport() {
        let facts = Facts()
            .add(10, parent: 1, ["keyed-gui"], executable: "/Applications/Keyed.app/keyed", app: Self.app)
            .add(20, parent: 10, tty: "/dev/ttys020", ["/usr/bin/login"])
        facts.listening[10] = [Self.socket, "/var/folders/xx/C/keyed-ipc-501"]
        facts.outputs[["/Applications/Keyed.app/keyed", "front", Self.socket]] = "/dev/ttys020"
        #expect(Self.route.readFront(appPid: 10, facts: facts, reported: [["KEYED_SOCKET": "unix:\(Self.socket)"], ["OTHER": "x"]]) == .tty("/dev/ttys020"))
        #expect(Self.route.readFront(appPid: 10, facts: facts, reported: [["KEYED_SOCKET": "/elsewhere/sock"]]) == .unknown(.ambiguous))
        #expect(Self.route.readFront(appPid: 10, facts: facts, reported: []) == .unknown(.ambiguous))
        #expect(facts.ran == [["/Applications/Keyed.app/keyed", "front", Self.socket]])
    }

    @Test func aRouteWithoutAFrontReaderReadsNoFront() {
        let route = KeyedSurfaceRoute(name: "Linked", apps: [Self.app], key: "LINK", focus: .url(prefix: "linked://"))
        #expect(route.readFront(appPid: 10, facts: Self.facts(), reported: []) == nil)
    }
}
