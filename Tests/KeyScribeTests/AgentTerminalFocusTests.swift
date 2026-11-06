import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct AgentTerminalFocusTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        var events: [String] { lock.withLock { _events } }
        func record(_ event: String) { lock.withLock { _events.append(event) } }
    }

    private static let herdr = OpenAction.layer(PaneLayer("herdr", commands: [
        PaneCommand(["/usr/bin/env", "HERDR_SOCKET_PATH=/s.sock", "/bin/herdr", "agent", "focus", "w1:p2"]),
    ]))
    private static let tmux = OpenAction.layer(PaneLayer("tmux", commands: [
        PaneCommand(["/bin/tmux", "-S", "/t", "select-window", "-t", "%4"]),
        PaneCommand(["/bin/tmux", "-S", "/t", "select-pane", "-t", "%4"]),
        PaneCommand(["/bin/tmux", "-S", "/t", "switch-client", "-c", "/dev/ttys003", "-t", "%4"]),
    ]))
    private static let ghosttyApp = "com.mitchellh.ghostty"
    private static let ghostty: [OpenAction] = [
        .select(.script(app: ghosttyApp, pid: 10, body: "find ttys004")), .activate(app: ghosttyApp, pid: 10),
    ]

    private func focuser(
        _ steps: [OpenAction], failing: [String: String] = [:], selection: TerminalSelection = .selected, opens: Bool = true,
        apps: [Int: String] = [10: "Ghostty"], appPid: Int? = 10, asks: Bool = false, calls: Calls,
        waitOnPlan: DispatchSemaphore? = nil, onRun: (@Sendable ([String]) -> Void)? = nil,
        onOpen: (@Sendable () -> Void)? = nil, connector: TerminalSelection = .selected
    ) -> AgentTerminalFocus {
        AgentTerminalFocus(
            plan: { _ in
                waitOnPlan?.wait()
                calls.record("plan")
                return steps
            },
            run: { argv in
                calls.record(argv.joined(separator: " "))
                onRun?(argv)
                return failing[argv.joined(separator: " ")].map { (2, $0) } ?? (0, "")
            },
            script: { app, pid, body, asking in
                if asks { await asking() }
                calls.record("script \(app) \(pid) \(body)")
                return selection
            },
            openURL: { url in
                calls.record("open \(url)")
                onOpen?()
                return opens
            },
            connector: { session in
                calls.record("connector \(session)")
                return connector
            },
            running: { _, _ in appPid.map { ($0, "Ghostty") } },
            activate: { pid in
                calls.record("activate \(pid)")
                return apps[pid]
            })
    }

    @Test func aSelectedTerminalTabIsAnExactOpenAndItsAppComesForward() async {
        let calls = Calls()
        #expect(await focuser(Self.ghostty, calls: calls).focus(session: "s1", pid: 30, asking: { _ in }) == .exact)
        #expect(calls.events == ["plan", "script com.mitchellh.ghostty 10 find ttys004", "activate 10"])
    }

    @Test func herdrSelectsThePaneThroughItsOwnSocketBeforeTheTerminalIsSelected() async {
        let calls = Calls()
        #expect(await focuser([Self.herdr] + Self.ghostty, calls: calls).focus(session: "s1", pid: 30, asking: { _ in }) == .exact)
        #expect(calls.events == [
            "plan", "/usr/bin/env HERDR_SOCKET_PATH=/s.sock /bin/herdr agent focus w1:p2",
            "script com.mitchellh.ghostty 10 find ttys004", "activate 10",
        ])
    }

    @Test func tmuxSelectsThePaneAndShowsItOnTheChosenClient() async {
        let calls = Calls()
        #expect(await focuser([Self.tmux] + Self.ghostty, calls: calls).focus(session: "s1", pid: 30, asking: { _ in }) == .exact)
        #expect(calls.events.dropFirst().prefix(3) == [
            "/bin/tmux -S /t select-window -t %4", "/bin/tmux -S /t select-pane -t %4",
            "/bin/tmux -S /t switch-client -c /dev/ttys003 -t %4",
        ])
    }

    @Test func aMultiplexerThatFailedIsNamedInTheResult() async {
        let calls = Calls()
        let failing = ["/usr/bin/env HERDR_SOCKET_PATH=/s.sock /bin/herdr agent focus w1:p2": "no such pane"]
        #expect(await focuser([Self.herdr] + Self.ghostty, failing: failing, calls: calls).focus(session: "s1", pid: 30, asking: { _ in })
            == .pane(app: "Ghostty", multiplexer: "herdr", uncertain: false))
    }

    @Test func aRouteThatMustComeForwardBeforeSelectingRunsInItsOwnOrder() async {
        let calls = Calls()
        #expect(await focuser(Self.ghostty.reversed(), calls: calls).focus(session: "s1", pid: 30, asking: { _ in }) == .exact)
        #expect(calls.events == ["plan", "activate 10", "script com.mitchellh.ghostty 10 find ttys004"])
    }

    @Test(arguments: [
        (TerminalSelection.selected, AgentFocusResult.exact),
        (.notFound, .app("cmux")),
        (.unsupported, .unsupported("cmux")),
        (.outdated, .connectorOutdated("cmux")),
    ])
    func aTerminalOnlyTheAgentsConnectorCanFocusAsksItForTheSession(answer: TerminalSelection, result: AgentFocusResult) async {
        let calls = Calls()
        let cmux: [OpenAction] = [.select(.connector), .activate(app: "com.cmuxterm.app", pid: 10)]
        #expect(await focuser(cmux, apps: [10: "cmux"], calls: calls, connector: answer).focus(session: "s1", pid: 30, asking: { _ in }) == result)
        #expect(calls.events == ["plan", "connector s1", "activate 10"])
    }

    @Test func aTabTheTerminalCouldNotFindLeavesOnlyTheTerminalApp() async {
        let calls = Calls()
        #expect(await focuser(Self.ghostty, selection: .notFound, calls: calls).focus(session: "s1", pid: 30, asking: { _ in }) == .app("Ghostty"))
        #expect(calls.events.last == "activate 10")
    }

    @Test func aTerminalNotAllowedToBeControlledSaysSo() async {
        let calls = Calls()
        #expect(await focuser(Self.ghostty, selection: .notAllowed, calls: calls).focus(session: "s1", pid: 30, asking: { _ in }) == .notAllowed("Ghostty"))
    }

    @Test func aTerminalAppThatIsNotRunningShowsNothing() async {
        let calls = Calls()
        #expect(await focuser(Self.ghostty, appPid: nil, calls: calls).focus(session: "s1", pid: 30, asking: { _ in }) == .none)
        #expect(calls.events == ["plan"])
    }

    @Test func warpIsAskedToShowItsSessionSinceNothingConfirmsWhichTabItSelected() async {
        let calls = Calls()
        let warp: [OpenAction] = [.select(.url("warp://session/abc")), .activate(app: "dev.warp.Warp-Stable", pid: 10)]
        #expect(await focuser(warp, apps: [10: "Warp"], calls: calls).focus(session: "s1", pid: 30, asking: { _ in }) == .requested("Warp"))
        #expect(calls.events == ["plan", "open warp://session/abc", "activate 10"])
        #expect(await focuser(warp, opens: false, apps: [10: "Warp"], calls: Calls()).focus(session: "s1", pid: 30, asking: { _ in }) == .app("Warp"))
    }

    @Test func aTerminalWithNoRouteToTryAsksTheUserToSelectIt() async {
        let calls = Calls()
        #expect(await focuser([.activate(app: "dev.warp.Warp-Stable", pid: 10)], apps: [10: "Warp"], calls: calls).focus(session: "s1", pid: 30, asking: { _ in }) == .unsupported("Warp"))
        #expect(await focuser([.unsupported(app: "net.kovidgoyal.kitty", pid: 10)], apps: [10: "kitty"], calls: calls).focus(session: "s1", pid: 30, asking: { _ in }) == .unsupported("kitty"))
        #expect(await focuser([.activate(app: "dev.warp.Warp-Stable", pid: 10)], apps: [:], calls: calls).focus(session: "s1", pid: 30, asking: { _ in }) == .none)
    }

    @Test func aHerdrPaneThatCouldNotBeIdentifiedIsNamedInTheResult() async {
        let calls = Calls()
        let unknown = OpenAction.layer(.unresolved("herdr"))
        #expect(await focuser([unknown] + Self.ghostty, calls: calls).focus(session: "s1", pid: 30, asking: { _ in })
            == .pane(app: "Ghostty", multiplexer: "herdr", uncertain: false))
        #expect(calls.events == ["plan", "script com.mitchellh.ghostty 10 find ttys004", "activate 10"])
    }

    @Test func onlyTheAlreadyDoneAnswerOfAFailedCommandCountsAsSelected() async {
        let focus = OpenAction.layer(PaneLayer("Zellij", commands: [PaneCommand(["/bin/zellij", "focus"], alreadyDone: "is already focused")]))
        let already = ["/bin/zellij focus": "Pane Terminal(2) is already focused"]
        #expect(await focuser([focus] + Self.ghostty, failing: already, calls: Calls()).focus(session: "s1", pid: 30, asking: { _ in }) == .exact)
        let missing = ["/bin/zellij focus": "Pane with id Terminal(2) not found"]
        #expect(await focuser([focus] + Self.ghostty, failing: missing, calls: Calls()).focus(session: "s1", pid: 30, asking: { _ in })
            == .pane(app: "Ghostty", multiplexer: "Zellij", uncertain: false))
    }

    @Test func aLayerThatCannotConfirmWhichWindowItMovedSaysSo() async {
        let unsure = OpenAction.layer(PaneLayer("Zellij", commands: [PaneCommand(["/bin/zellij", "focus"])], confirmed: false))
        let calls = Calls()
        #expect(await focuser([unsure] + Self.ghostty, calls: calls).focus(session: "s1", pid: 30, asking: { _ in })
            == .pane(app: "Ghostty", multiplexer: "Zellij", uncertain: true))
        #expect(calls.events.contains("/bin/zellij focus"))
    }

    @Test func cancellingDuringATmuxCommandChangesNothingMore() async {
        let calls = Calls()
        let release = DispatchSemaphore(value: 0)
        let focus = focuser([Self.tmux] + Self.ghostty, calls: calls, onRun: { _ in release.wait() })
        let task = Task { await focus.focus(session: "s1", pid: 30, asking: { _ in }) }
        while calls.events.count < 2 { await Task.yield() }
        task.cancel()
        release.signal()
        #expect(await task.value == .none)
        #expect(calls.events == ["plan", "/bin/tmux -S /t select-window -t %4"])
    }

    @Test func cancellingWhileWarpOpensItsSessionDoesNotBringItForward() async {
        let calls = Calls()
        let warp: [OpenAction] = [.select(.url("warp://session/abc")), .activate(app: "dev.warp.Warp-Stable", pid: 10)]
        let holder = TaskHolder()
        let focus = focuser(warp, apps: [10: "Warp"], calls: calls, onOpen: { holder.task?.cancel() })
        holder.task = Task { await focus.focus(session: "s1", pid: 30, asking: { _ in }) }
        #expect(await holder.task?.value == AgentFocusResult.none)
        #expect(calls.events == ["plan", "open warp://session/abc"])
    }

    final class TaskHolder: @unchecked Sendable {
        var task: Task<AgentFocusResult, Never>?
    }

    @Test func aTerminalThatAsksForPermissionNamesItselfWhileTheQuestionIsOpen() async {
        let calls = Calls()
        let asked = Calls()
        _ = await focuser(Self.ghostty, asks: true, calls: calls).focus(session: "s1", pid: 30, asking: { asked.record($0) })
        #expect(asked.events == ["Ghostty"])
    }

    @Test func noStepsShowNothing() async {
        #expect(await focuser([], calls: Calls()).focus(session: "s1", pid: 30, asking: { _ in }) == .none)
        #expect(await focuser([Self.herdr], calls: Calls()).focus(session: "s1", pid: 30, asking: { _ in }) == .none)
    }

    @Test func cancellingWhileThePlanIsGatheredDoesNothing() async {
        let calls = Calls()
        let gate = DispatchSemaphore(value: 0)
        let focus = focuser([Self.herdr] + Self.ghostty, calls: calls, waitOnPlan: gate)
        let task = Task { await focus.focus(session: "s1", pid: 30, asking: { _ in }) }
        await Task.yield()
        task.cancel()
        gate.signal()
        #expect(await task.value == .none)
        #expect(calls.events.allSatisfy { $0 == "plan" })
    }

    @Test(arguments: [
        (AgentFocusResult.exact, HUDState.commandDone(summary: "Opened backend", detail: "Coding agent")),
        (.requested("Warp"), .commandDone(summary: "Asked Warp to show backend", detail: "Coding agent")),
        (.app("Ghostty"), .advisory(message: "Brought Ghostty forward. Couldn\u{2019}t find backend\u{2019}s tab. Your recipient is backend")),
        (.pane(app: "Ghostty", multiplexer: "Zellij", uncertain: true),
         .advisory(message: "Brought Ghostty forward. Couldn\u{2019}t confirm backend\u{2019}s Zellij pane. Your recipient is backend")),
        (.pane(app: "Ghostty", multiplexer: "herdr", uncertain: false),
         .advisory(message: "Brought Ghostty forward. Couldn\u{2019}t select backend\u{2019}s herdr pane. Your recipient is backend")),
        (.unsupported("kitty"), .advisory(message: "Brought kitty forward. Select backend\u{2019}s terminal yourself. Your recipient is backend")),
        (.notAllowed("Ghostty"), .error(
            message: "Brought Ghostty forward. Couldn\u{2019}t select backend\u{2019}s tab without access to Ghostty. Your recipient is backend",
            action: .openAutomationSettings)),
        (.connectorOutdated("cmux"), .advisory(
            message: "Brought cmux forward. Update the Claude Code connector in Settings, then run /reload-plugins in backend to open its tab. Your recipient is backend")),
        (.none, .advisory(message: "Nothing showing backend could be brought forward. Your recipient is backend")),
    ])
    func eachResultSaysWhatHappened(result: AgentFocusResult, state: HUDState) {
        #expect(result.hudState(handle: "backend", detail: "Coding agent") == state)
    }

    @Test(arguments: [
        (AgentFocusResult.exact, "Opened backend"),
        (.requested("Warp"), "Asked Warp to show backend"),
        (.app("Ghostty"), "Brought Ghostty forward; backend\u{2019}s tab not found"),
        (.pane(app: "Ghostty", multiplexer: "Zellij", uncertain: true), "Brought Ghostty forward; backend\u{2019}s Zellij pane not confirmed"),
        (.pane(app: "Ghostty", multiplexer: "herdr", uncertain: false), "Brought Ghostty forward; backend\u{2019}s herdr pane not selected"),
        (.unsupported("kitty"), "Brought kitty forward; backend\u{2019}s terminal not selected"),
        (.notAllowed("Ghostty"), "Brought Ghostty forward; no access to select backend\u{2019}s tab"),
        (.connectorOutdated("cmux"), "Brought cmux forward; the Claude Code connector needs an update"),
        (.none, "Nothing showing backend was brought forward"),
    ])
    func eachResultHasAHistorySummaryThatNeverReadsAsSent(result: AgentFocusResult, summary: String) {
        #expect(result.historySummary(handle: "backend") == summary)
        #expect(!summary.localizedCaseInsensitiveContains("sent"))
    }
}
