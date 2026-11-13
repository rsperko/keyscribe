import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct AgentFrontTests {
    nonisolated final class Facts: TerminalFacts, @unchecked Sendable {
        var table: [Int: TerminalProcess] = [:]
        var outputs: [[String]: String] = [:]
        var listening: [Int: Set<String>] = [:]

        func add(_ pid: Int, parent: Int?, tty: String?, _ name: String) -> Facts {
            table[pid] = TerminalProcess(pid: pid, parent: parent, tty: tty, arguments: [name], environment: [:], executable: name, app: nil)
            return self
        }

        func process(_ pid: Int) -> TerminalProcess? { table[pid] }
        func processes(named name: String) -> [TerminalProcess]? { [] }
        func processes(onTTY tty: String) -> [TerminalProcess]? { table.values.filter { $0.tty == tty } }
        func children(of pid: Int) -> [TerminalProcess]? { table.values.filter { $0.parent == pid } }
        func socketOwners(in directory: String) -> [String: Int]? { nil }
        func listeningSockets(of pid: Int) -> Set<String>? { listening[pid] ?? [] }
        func run(_ argv: [String]) -> (status: Int32, output: String) { outputs[argv].map { (0, $0) } ?? (1, "") }

        func showing(tmuxPane tty: String) -> Facts {
            outputs[["tmux", "list-clients", "-F", "#{client_tty}\t#{pane_tty}"]] = "/dev/ttys001\t\(tty)"
            return self
        }
    }

    final class Sequence<Value>: @unchecked Sendable {
        var values: [Value]
        init(_ values: [Value]) { self.values = values }
        func next() -> Value { values.count > 1 ? values.removeFirst() : values[0] }
    }

    final class Front: @unchecked Sendable {
        var apps: [FrontApp?]
        init(_ apps: FrontApp?...) { self.apps = apps }
        func next() -> FrontApp? { apps.count > 1 ? apps.removeFirst() : apps.first ?? nil }
    }

    nonisolated private static let ghostty = "com.mitchellh.ghostty"
    private static let ghosttyApp = FrontApp(bundle: ghostty, pid: 10, name: "Ghostty")
    nonisolated private static let safari = FrontApp(bundle: "com.apple.Safari", pid: 11, name: "Safari")
    nonisolated private static let facts = Facts()
        .add(30, parent: 1, tty: "/dev/ttys004", "claude")
        .add(40, parent: 1, tty: "/dev/ttys005", "pi")

    final class Replies: @unchecked Sendable {
        var replies: [TerminalRead]
        init(_ replies: [TerminalRead]) { self.replies = replies }
        func next() -> TerminalRead { replies.count > 1 ? replies.removeFirst() : replies[0] }
    }

    private func front(
        _ front: Front, reply: TerminalRead = .value("/dev/ttys004"), then: [TerminalRead] = [],
        asked: (@Sendable (String) -> Void)? = nil, facts: [Facts] = [AgentFrontTests.facts],
        onSecondRead: (@Sendable () -> Void)? = nil
    ) -> AgentFront {
        let replies = Replies([reply] + then)
        let facts = Sequence(facts)
        let reads = Sequence(Array(1...3))
        return AgentFront(
            surfaces: .builtIn, frontmost: { front.next() },
            read: { app, pid, body, asking in
                #expect(app == Self.ghostty && pid == 10 && body == ScriptedTerminalRoute.ghostty.frontScript)
                if let asked { await asking(); asked(app) }
                if reads.next() == 2 { onSecondRead?() }
                return replies.next()
            },
            facts: { facts.next() })
    }

    nonisolated private static func tmux(showing tty: String) -> Facts {
        Facts()
            .add(12, parent: 1, tty: "/dev/ttys001", "tmux")
            .add(30, parent: 1, tty: "/dev/ttys004", "claude")
            .add(40, parent: 1, tty: "/dev/ttys005", "pi")
            .showing(tmuxPane: tty)
    }

    @Test func cmuxIsAskedForItsFocusedTerminalAndAnsweredWithThatSurface() async {
        let cmux = FrontApp(bundle: "com.cmuxterm.app", pid: 10, name: "cmux")
        let facts = Facts()
            .add(20, parent: 10, tty: "/dev/ttys021", "/usr/bin/login")
            .add(40, parent: 10, tty: "/dev/ttys022", "/usr/bin/login")
        facts.table[30] = TerminalProcess(
            pid: 30, parent: 20, tty: "/dev/ttys021", arguments: ["claude"], environment: ["CMUX_SURFACE_ID": "A"], executable: "claude", app: nil)
        facts.table[50] = TerminalProcess(
            pid: 50, parent: 40, tty: "/dev/ttys022", arguments: ["pi"], environment: ["CMUX_SURFACE_ID": "B"], executable: "pi", app: nil)
        let front = AgentFront(
            surfaces: .builtIn, frontmost: { cmux },
            read: { app, pid, body, _ in
                #expect(app == "com.cmuxterm.app" && pid == 10 && body == ResolvedSurfaces.builtIn.terminal("com.cmuxterm.app")?.frontScript)
                return .value("A")
            },
            facts: { facts })
        #expect(await front.check(agent: 30) == .shown)
        #expect(await front.check(agent: 50) == .elsewhere)
    }

    @Test func aMultiplexerPaneThatChangesBehindTheSameTabIsUnknown() async {
        let steady = front(Front(Self.ghosttyApp), reply: .value("/dev/ttys001"), facts: [Self.tmux(showing: "/dev/ttys004")])
        #expect(await steady.check(agent: 30) == .shown)
        let moved = front(
            Front(Self.ghosttyApp), reply: .value("/dev/ttys001"),
            facts: [Self.tmux(showing: "/dev/ttys004"), Self.tmux(showing: "/dev/ttys004"), Self.tmux(showing: "/dev/ttys005")])
        #expect(await moved.check(agent: 30) == .unknown(.changed))
    }

    @Test func aWindowThatChangesDuringTheReadIsUnknownAndTheReadingNamesItsWindow() async {
        let first = FrontApp(bundle: Self.ghostty, pid: 10, name: "Ghostty", window: "cg:3")
        let second = FrontApp(bundle: Self.ghostty, pid: 10, name: "Ghostty", window: "cg:5")
        let agents = [AgentFrontCandidate(id: "a", pid: 30)]
        #expect(await front(Front(first)).shown(among: agents) == FrontSession(id: "a", app: first))
        let apps = Front(first)
        let moved = front(apps, onSecondRead: { apps.apps = [second] })
        #expect(await moved.shown(among: agents) == nil)
    }

    @Test func anAppThatChangesDuringTheSecondReadIsUnknown() async {
        let apps = Front(Self.ghosttyApp)
        let check = front(apps, onSecondRead: { apps.apps = [Self.safari] })
        #expect(await check.check(agent: 30) == .unknown(.changed))
    }

    @Test func aSingleReadCheckReadsTheTerminalAndTheFrontAppOnce() async {
        final class Count: @unchecked Sendable { var reads = 0; var fronts = 0 }
        let count = Count()
        var check = AgentFront(
            surfaces: .builtIn, frontmost: { count.fronts += 1; return Self.ghosttyApp },
            read: { _, _, _, _ in count.reads += 1; return .value("/dev/ttys004") },
            facts: { Self.facts })
        check.confirming = false
        let agents = [AgentFrontCandidate(id: "a", pid: 30), AgentFrontCandidate(id: "b", pid: 40)]
        #expect(await check.shown(among: agents) == FrontSession(id: "a", app: Self.ghosttyApp))
        #expect(count.reads == 1 && count.fronts == 1)
        #expect(AgentFront.withoutAsking(.builtIn).confirming == false)
        #expect(AgentFront.confirmingWithoutAsking(.builtIn).confirming)
    }

    @Test func anAgentInTheFrontTerminalTabIsShown() async {
        let check = front(Front(Self.ghosttyApp))
        #expect(await check.check(agent: 30) == .shown)
        #expect(await check.check(agent: 40) == .elsewhere)
    }

    @Test func theOneAgentShownInTheFrontTerminalIsPickedOutOfSeveral() async {
        let agents = [AgentFrontCandidate(id: "a", pid: 30), AgentFrontCandidate(id: "b", pid: 40)]
        #expect(await front(Front(Self.ghosttyApp)).shown(among: agents) == FrontSession(id: "a", app: Self.ghosttyApp))
        #expect(await front(Front(Self.ghosttyApp), reply: .value("/dev/ttys005")).shown(among: agents) == FrontSession(id: "b", app: Self.ghosttyApp))
        #expect(await front(Front(Self.ghosttyApp), reply: .value("/dev/ttys009")).shown(among: agents) == nil)
        #expect(await front(Front(Self.safari)).shown(among: agents) == nil)
        #expect(await front(Front(Self.ghosttyApp), reply: .notAllowed).shown(among: agents) == nil)
    }

    @Test func aTerminalWithoutAScriptIsReadThroughItsOwnCommandsAndNeverAskedForAutomation() async throws {
        let surfaces = try AgentSurfaces(terminals: [KeyedSurfaceRoute(
            name: "Keyed", apps: ["dev.example.keyed"], key: "KEYED_PANE", focus: .url(prefix: "keyed://"),
            front: { terminal, _, facts in
                let answer = facts.run(["keyed", "front", "\(terminal.pid)"])
                return answer.status == 0 ? .tty(answer.output) : .unknown(.unreadable("Keyed"))
            })]).resolve()
        let facts = Facts().add(10, parent: 1, tty: nil, "/Applications/Keyed.app/keyed").add(30, parent: 10, tty: "/dev/ttys004", "claude")
            .add(40, parent: 10, tty: "/dev/ttys005", "pi")
        facts.outputs[["keyed", "front", "10"]] = "/dev/ttys004"
        let keyed = FrontApp(bundle: "dev.example.keyed", pid: 10, name: "Keyed")
        let front = AgentFront(
            surfaces: surfaces, frontmost: { keyed },
            read: { _, _, _, _ in
                Issue.record("a terminal without a script is never sent one")
                return .failed
            },
            facts: { facts })
        #expect(await front.check(agent: 30) == .shown)
        #expect(await front.check(agent: 40) == .elsewhere)
        facts.outputs = [:]
        #expect(await front.check(agent: 30) == .unknown(.unreadable("Keyed")))
        let blind = AgentFront(
            surfaces: try AgentSurfaces(terminals: [KeyedSurfaceRoute(name: "Keyed", apps: ["dev.example.keyed"], key: "K", focus: .url(prefix: "k://"))]).resolve(),
            frontmost: { keyed }, facts: { facts })
        #expect(await blind.check(agent: 30) == .unknown(.unsupported("dev.example.keyed")))
    }

    @Test func aTerminalListeningOnSeveralSocketsIsReadThroughTheOneTheCheckedConversationReports() async throws {
        let surfaces = try AgentSurfaces(terminals: [KeyedSurfaceRoute(
            name: "Keyed", apps: ["dev.example.keyed"], key: "KEYED_WINDOW", socket: "KEYED_SOCKET",
            focus: .command { _, _, _ in nil },
            front: { _, socket, facts in
                let answer = facts.run(["keyed", "front", socket ?? ""])
                return answer.status == 0 ? .tty(answer.output) : .unknown(.unreadable("Keyed"))
            })]).resolve()
        let facts = Facts().add(10, parent: 1, tty: nil, "/Applications/Keyed.app/keyed").add(30, parent: 10, tty: "/dev/ttys004", "claude")
        facts.listening[10] = ["/tmp/keyed-10", "/var/folders/xx/C/keyed-ipc-501"]
        facts.outputs[["keyed", "front", "/tmp/keyed-10"]] = "/dev/ttys004"
        let keyed = FrontApp(bundle: "dev.example.keyed", pid: 10, name: "Keyed")
        let front = AgentFront(surfaces: surfaces, frontmost: { keyed }, facts: { facts })
        #expect(await front.check(agent: 30, environment: ["KEYED_SOCKET": "unix:/tmp/keyed-10"]) == .shown)
        #expect(await front.check(agent: 30) == .unknown(.ambiguous))
        let shown = await front.shown(among: [AgentFrontCandidate(id: "claude:s1", pid: 30, environment: ["KEYED_SOCKET": "unix:/tmp/keyed-10"])])
        #expect(shown?.id == "claude:s1")
    }

    @Test func aFrontAppWithoutATerminalRouteIsUnknown() async {
        let check = front(Front(Self.safari))
        #expect(await check.check(agent: 30) == .unknown(.unsupported("com.apple.Safari")))
        #expect(await front(Front(nil)).check(agent: 30) == .unknown(.noTerminal))
    }

    @Test func aRefusedOrFailedReadIsUnknownNotElsewhere() async {
        #expect(await front(Front(Self.ghosttyApp), reply: .notAllowed).check(agent: 30) == .unknown(.notAllowed(Self.ghostty)))
        #expect(await front(Front(Self.ghosttyApp), reply: .failed).check(agent: 30) == .unknown(.unreadable(Self.ghostty)))
        #expect(await front(Front(Self.ghosttyApp), reply: .value("")).check(agent: 30) == .unknown(.noTerminal))
    }

    @Test func aFrontAppThatChangesDuringTheReadIsUnknown() async {
        let check = front(Front(Self.ghosttyApp, Self.safari))
        #expect(await check.check(agent: 30) == .unknown(.changed))
    }

    @Test func aTabThatChangesInTheSameTerminalDuringTheReadIsUnknown() async {
        let check = front(Front(Self.ghosttyApp), then: [.value("/dev/ttys005")])
        #expect(await check.check(agent: 30) == .unknown(.changed))
        #expect(await front(Front(Self.ghosttyApp), then: [.failed]).check(agent: 30) == .unknown(.unreadable(Self.ghostty)))
    }

    @Test func onlyTheFirstReadMayAskForAutomationAndOnlyThroughTheCaller() async {
        let asked = AgentTerminalFocusTests.Calls()
        let check = front(Front(Self.ghosttyApp), asked: { asked.record($0) })
        let names = AgentTerminalFocusTests.Calls()
        #expect(await check.check(agent: 30, asking: { names.record($0) }) == .shown)
        #expect(asked.events == [Self.ghostty, Self.ghostty])
        #expect(names.events == ["Ghostty"])
    }
}
