import Foundation
import Testing
@testable import KeyScribeKit

struct TerminalRoutesTests {
    final class Facts: TerminalFacts, @unchecked Sendable {
        var table: [Int: TerminalProcess] = [:]
        var outputs: [[String]: String] = [:]
        var owners: [String: [String: Int]] = [:]
        var unreadableTTYs: Set<String> = []
        var childrenUnreadable = false
        var namesUnreadable = false
        private(set) var ran: [[String]] = []

        @discardableResult
        func add(
            _ pid: Int, parent: Int?, tty: String? = nil, _ arguments: [String], executable: String? = nil,
            environment: [String: String] = [:], app: String? = nil, foreground: Bool = true
        ) -> Facts {
            table[pid] = TerminalProcess(
                pid: pid, parent: parent, tty: tty, arguments: arguments, environment: environment,
                executable: executable ?? arguments.first ?? "", app: app, foreground: foreground)
            return self
        }

        func process(_ pid: Int) -> TerminalProcess? { table[pid] }
        func processes(named name: String) -> [TerminalProcess]? {
            guard !namesUnreadable else { return nil }
            return table.values.filter { ($0.executable as NSString).lastPathComponent == name }.sorted { $0.pid < $1.pid }
        }
        func processes(onTTY tty: String) -> [TerminalProcess]? {
            guard !unreadableTTYs.contains(tty) else { return nil }
            return table.values.filter { $0.tty == tty }.sorted { $0.pid < $1.pid }
        }
        func children(of pid: Int) -> [TerminalProcess]? {
            guard !childrenUnreadable else { return nil }
            return table.values.filter { $0.parent == pid }.sorted { $0.pid < $1.pid }
        }
        func socketOwners(in directory: String) -> [String: Int]? { owners[directory] }
        func run(_ argv: [String]) -> (status: Int32, output: String) {
            ran.append(argv)
            return outputs[argv].map { (0, $0) } ?? (1, "")
        }
    }

    private static let ghostty = "com.mitchellh.ghostty"
    private static let herdr = "/opt/homebrew/bin/herdr"
    private static let tmux = "/opt/homebrew/bin/tmux"
    private static let herdrSocket = "/Users/me/.config/herdr/herdr.sock"

    private static func herdrLayer(socket: String = herdrSocket, pane: String = "w1:p2") -> OpenAction {
        .layer(PaneLayer("herdr", commands: [PaneCommand(["/usr/bin/env", "HERDR_SOCKET_PATH=\(socket)", herdr, "agent", "focus", pane])]))
    }

    private static func tmuxLayer(client: String) -> OpenAction {
        let tmux = [Self.tmux, "-S", "/private/tmp/tmux-501/default"]
        return .layer(PaneLayer("tmux", commands: [
            PaneCommand(tmux + ["select-window", "-t", "%4"]), PaneCommand(tmux + ["select-pane", "-t", "%4"]),
            PaneCommand(tmux + ["switch-client", "-c", client, "-t", "%4"]),
        ]))
    }

    @Test func anAgentInAGhosttyTabSelectsItsTerminalByTty() {
        let facts = Facts()
            .add(30, parent: 20, tty: "/dev/ttys004", ["claude"])
            .add(20, parent: 10, tty: "/dev/ttys004", ["/usr/bin/login", "-flp", "me"])
            .add(10, parent: 1, ["/Applications/Ghostty.app/Contents/MacOS/ghostty"], app: Self.ghostty)
        #expect(TerminalRoutes.plan(agent: 30, facts: facts) == ScriptedTerminalRoute.ghostty.open(pid: 10, ttys: ["/dev/ttys004"]))
    }

    @Test func aWrapperPtyBetweenTheAgentAndTheTerminalStillReachesTheTerminalsTab() {
        let facts = Facts()
            .add(40, parent: 30, tty: "/dev/ttys060", ["claude"])
            .add(30, parent: 20, tty: "/dev/ttys058", ["python3", "ptywrap.py"])
            .add(20, parent: 10, tty: "/dev/ttys058", ["/usr/bin/login"])
            .add(10, parent: 1, ["ghostty"], app: Self.ghostty)
        #expect(TerminalRoutes.plan(agent: 40, facts: facts) == ScriptedTerminalRoute.ghostty.open(pid: 10, ttys: ["/dev/ttys058", "/dev/ttys060"]))
    }

    @Test func terminalAppAndITermAreSelectedTheSameWay() {
        let terminal = Facts()
            .add(30, parent: 10, tty: "/dev/ttys020", ["-zsh"])
            .add(10, parent: 1, ["Terminal"], app: "com.apple.Terminal")
        #expect(TerminalRoutes.plan(agent: 30, facts: terminal) == ScriptedTerminalRoute.terminal.open(pid: 10, ttys: ["/dev/ttys020"]))
        let iterm = Facts()
            .add(30, parent: 10, tty: "/dev/ttys021", ["-zsh"])
            .add(10, parent: 1, ["iTerm2"], app: "com.googlecode.iterm2")
        #expect(TerminalRoutes.plan(agent: 30, facts: iterm) == ScriptedTerminalRoute.iterm.open(pid: 10, ttys: ["/dev/ttys021"]))
    }

    @Test func iTermSessionsThatOutlivedAnITermRestartAreStillITerms() {
        let facts = Facts()
            .add(30, parent: 20, tty: "/dev/ttys021", ["claude"])
            .add(20, parent: 15, tty: "/dev/ttys021", ["/usr/bin/login"])
            .add(15, parent: 1, ["/Users/me/Library/Application Support/iTerm2/iTermServer-3.7.6", "/Users/me/iterm2-daemon-1.socket"])
        #expect(TerminalRoutes.plan(agent: 30, facts: facts) == ScriptedTerminalRoute.iterm.open(pid: 15, ttys: ["/dev/ttys021"]))
    }

    @Test func warpOpensTheSessionsOwnFocusURL() {
        let facts = Facts()
            .add(30, parent: 20, tty: "/dev/ttys030", ["claude"], environment: ["WARP_FOCUS_URL": "warp://session/inner"])
            .add(20, parent: 10, tty: "/dev/ttys030", ["-zsh"], environment: ["WARP_FOCUS_URL": "warp://session/abc"])
            .add(10, parent: 1, ["stable"], app: "dev.warp.Warp-Stable")
        #expect(TerminalRoutes.plan(agent: 30, facts: facts) == [.select(.url("warp://session/abc")), .activate(app: "dev.warp.Warp-Stable", pid: 10)])
    }

    @Test func warpWithoutAFocusURLOnlyComesForward() {
        let facts = Facts()
            .add(30, parent: 10, tty: "/dev/ttys030", ["claude"])
            .add(10, parent: 1, ["stable"], app: "dev.warp.Warp-Stable")
        #expect(TerminalRoutes.plan(agent: 30, facts: facts) == [.activate(app: "dev.warp.Warp-Stable", pid: 10)])
    }

    @Test func anAgentInCmuxFocusesTheSurfaceItsProcessesNameThenCmuxComesForward() throws {
        let facts = Facts()
            .add(30, parent: 20, tty: "/dev/ttys050", ["pi"], environment: ["CMUX_SURFACE_ID": "7D77E5A3-\"1"])
            .add(20, parent: 10, tty: "/dev/ttys050", ["/usr/bin/login"])
            .add(10, parent: 1, ["/Applications/cmux.app/Contents/MacOS/cmux"], app: "com.cmuxterm.app")
        let plan = TerminalRoutes.plan(agent: 30, facts: facts)
        guard case .select(.script(let app, let pid, let body)) = try #require(plan.first) else {
            Issue.record("expected a script")
            return
        }
        #expect(app == "com.cmuxterm.app" && pid == 10)
        #expect(body.contains(#"terminal whose id is "7D77E5A3-\"1""#) && body.contains("focus"))
        #expect(plan.dropFirst() == [.activate(app: "com.cmuxterm.app", pid: 10)])
    }

    @Test func anAgentInTmuxInCmuxFocusesTheSurfaceItsClientRunsIn() {
        let socket = "/private/tmp/tmux-501/default"
        let facts = tmuxFacts(clients: "/dev/ttys005\t56\twork\t100\n")
        facts.table[10] = TerminalProcess(pid: 10, parent: 1, tty: nil, arguments: ["cmux"], environment: [:], executable: "cmux", app: "com.cmuxterm.app")
        facts.table[56]?.environment = ["CMUX_SURFACE_ID": "B"]
        facts.table[70]?.environment = ["CMUX_SURFACE_ID": "A"]
        let plan = TerminalRoutes.plan(agent: 70, facts: facts)
        #expect(plan.first == .layer(PaneLayer("tmux", commands: [
            PaneCommand([Self.tmux, "-S", socket, "select-window", "-t", "%4"]), PaneCommand([Self.tmux, "-S", socket, "select-pane", "-t", "%4"]),
            PaneCommand([Self.tmux, "-S", socket, "switch-client", "-c", "/dev/ttys005", "-t", "%4"]),
        ])))
        guard case .select(.script(_, _, let body)) = plan.dropFirst().first else {
            Issue.record("expected a script")
            return
        }
        #expect(body.contains(#"terminal whose id is "B""#))
    }

    @Test func anAgentInCmuxWithNoSurfaceIdInSightAsksItsConnectorThenCmuxComesForward() {
        let facts = Facts()
            .add(30, parent: 20, tty: "/dev/ttys050", ["claude"])
            .add(20, parent: 10, tty: "/dev/ttys050", ["/usr/bin/login"])
            .add(10, parent: 1, ["/Applications/cmux.app/Contents/MacOS/cmux"], app: "com.cmuxterm.app")
        #expect(TerminalRoutes.plan(agent: 30, facts: facts) == [.select(.connector), .activate(app: "com.cmuxterm.app", pid: 10)])
    }

    @Test func aTerminalOpenHasNoRouteForIsUnsupportedAndOnlyComesForward() {
        let facts = Facts()
            .add(30, parent: 10, tty: "/dev/ttys030", ["claude"])
            .add(10, parent: 1, ["kitty"], app: "net.kovidgoyal.kitty")
        #expect(TerminalRoutes.plan(agent: 30, facts: facts) == [.unsupported(app: "net.kovidgoyal.kitty", pid: 10)])
    }

    @Test func anAgentNoAppOwnsHasNoSteps() {
        let facts = Facts().add(30, parent: 1, ["claude"])
        #expect(TerminalRoutes.plan(agent: 30, facts: facts) == [])
        #expect(TerminalRoutes.plan(agent: 99, facts: facts) == [])
    }

    @Test func aParentLoopEnds() {
        let facts = Facts().add(30, parent: 20, ["claude"]).add(20, parent: 30, ["zsh"])
        #expect(TerminalRoutes.plan(agent: 30, facts: facts) == [])
    }

    private func herdrFacts(
        sessions: String = #"{"sessions":[{"name":"default","socket_path":"/Users/me/.config/herdr/herdr.sock"},{"name":"work","socket_path":"/Users/me/.config/herdr/sessions/work/herdr.sock"}]}"#,
        socket: String = herdrSocket, pane: String? = "w1:p2"
    ) -> Facts {
        var environment = ["HERDR_SOCKET_PATH": socket]
        environment["HERDR_PANE_ID"] = pane
        let facts = Facts()
            .add(50, parent: 45, tty: "/dev/ttys007", ["claude"], environment: environment)
            .add(45, parent: 40, tty: "/dev/ttys007", ["-zsh"])
            .add(40, parent: 1, [Self.herdr, "server"])
            .add(35, parent: 20, tty: "/dev/ttys000", [Self.herdr])
            .add(36, parent: 21, tty: "/dev/ttys009", [Self.herdr, "--session", "work"])
            .add(20, parent: 10, tty: "/dev/ttys000", ["/usr/bin/login"])
            .add(21, parent: 10, tty: "/dev/ttys009", ["/usr/bin/login"])
            .add(10, parent: 1, ["ghostty"], app: Self.ghostty)
        facts.outputs[[Self.herdr, "session", "list", "--json"]] = sessions
        return facts
    }

    @Test func anAgentInHerdrSelectsItsPaneThenTheTerminalTheHerdrClientRunsIn() {
        #expect(TerminalRoutes.plan(agent: 50, facts: herdrFacts()) == [
            Self.herdrLayer(),
        ] + ScriptedTerminalRoute.ghostty.open(pid: 10, ttys: ["/dev/ttys000"]))
    }

    @Test func aNamedHerdrSessionUsesTheClientAttachedToThatSession() {
        let socket = "/Users/me/.config/herdr/sessions/work/herdr.sock"
        #expect(TerminalRoutes.plan(agent: 50, facts: herdrFacts(socket: socket)) == [
            Self.herdrLayer(socket: socket),
        ] + ScriptedTerminalRoute.ghostty.open(pid: 10, ttys: ["/dev/ttys009"]))
    }

    @Test func aHerdrPaneThatCannotBeIdentifiedStaysAnUnselectedLayer() {
        #expect(TerminalRoutes.plan(agent: 50, facts: herdrFacts(pane: nil)) == [
            .layer(.unresolved("herdr")),
        ] + ScriptedTerminalRoute.ghostty.open(pid: 10, ttys: ["/dev/ttys000"]))
    }

    @Test func severalWindowsOnOneHerdrSessionAlwaysPickTheSameOne() {
        let facts = herdrFacts()
            .add(37, parent: 21, tty: "/dev/ttys009", [Self.herdr])
            .add(34, parent: 22, tty: "/dev/ttys011", [Self.herdr])
            .add(22, parent: 10, tty: "/dev/ttys011", ["/usr/bin/login"])
        #expect(TerminalRoutes.plan(agent: 50, facts: facts).suffix(2) == ScriptedTerminalRoute.ghostty.open(pid: 10, ttys: ["/dev/ttys011"])[...])
    }

    @Test func aHerdrSessionWithNoClientSelectsItsPaneAndShowsNothing() {
        let facts = herdrFacts(sessions: #"{"sessions":[]}"#)
        #expect(TerminalRoutes.plan(agent: 50, facts: facts) == [Self.herdrLayer()])
    }

    @Test(arguments: [
        ([herdr], "default"),
        ([herdr, "--session", "work"], "work"),
        (["herdr", "session", "attach", "work"], "work"),
        ([herdr, "server"], nil),
        ([herdr, "pane", "list"], nil),
        ([herdr, "--remote", "box"], nil),
        ([herdr, "--session"], nil),
    ] as [([String], String?)])
    func herdrClientsAreRecognizedByTheSessionTheyAttach(arguments: [String], session: String?) {
        #expect(HerdrRoute.clientSession(arguments) == session)
    }

    private func tmuxFacts(clients: String) -> Facts {
        let socket = "/private/tmp/tmux-501/default"
        let facts = Facts()
            .add(70, parent: 65, tty: "/dev/ttys012", ["claude"])
            .add(65, parent: 60, tty: "/dev/ttys012", ["-zsh"], environment: ["TMUX": "\(socket),60,0"])
            .add(60, parent: 1, ["tmux", "new", "-s", "work"], executable: Self.tmux)
            .add(55, parent: 50, tty: "/dev/ttys003", ["tmux", "attach"], executable: Self.tmux)
            .add(56, parent: 51, tty: "/dev/ttys005", ["tmux", "attach"], executable: Self.tmux)
            .add(50, parent: 10, tty: "/dev/ttys003", ["-zsh"])
            .add(51, parent: 10, tty: "/dev/ttys005", ["-zsh"])
            .add(10, parent: 1, ["iTerm2"], app: "com.googlecode.iterm2")
        facts.outputs[[Self.tmux, "-S", socket, "list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}\t#{session_name}"]] =
            "/dev/ttys011\t%1\tother\n/dev/ttys012\t%4\twork\n"
        facts.outputs[[Self.tmux, "-S", socket, "list-clients", "-F", "#{client_tty}\t#{client_pid}\t#{client_session}\t#{client_activity}"]] =
            clients
        return facts
    }

    @Test func anAgentInTmuxSelectsItsPaneThroughTheClientShowingItsSession() {
        let facts = tmuxFacts(clients: "/dev/ttys003\t55\tother\t900\n/dev/ttys005\t56\twork\t100\n")
        #expect(TerminalRoutes.plan(agent: 70, facts: facts) == [
            Self.tmuxLayer(client: "/dev/ttys005"),
        ] + ScriptedTerminalRoute.iterm.open(pid: 10, ttys: ["/dev/ttys005"]))
    }

    @Test func anAgentInTmuxIsFoundWhenOnlyTheAgentReportsTmuxBecauseItsLoginShellCannotBeRead() {
        let facts = tmuxFacts(clients: "/dev/ttys003\t55\tother\t900\n/dev/ttys005\t56\twork\t100\n")
        facts.table[70]?.environment = ["TMUX": "/private/tmp/tmux-501/default,60,0"]
        facts.table[65]?.environment = [:]
        #expect(TerminalRoutes.plan(agent: 70, facts: facts) == [
            Self.tmuxLayer(client: "/dev/ttys005"),
        ] + ScriptedTerminalRoute.iterm.open(pid: 10, ttys: ["/dev/ttys005"]))
    }

    @Test func withNoClientOnItsSessionTmuxSwitchesTheMostRecentlyUsedClient() {
        let facts = tmuxFacts(clients: "/dev/ttys005\t56\tother\t100\n/dev/ttys003\t55\tother\t900\n")
        #expect(TerminalRoutes.plan(agent: 70, facts: facts) == [
            Self.tmuxLayer(client: "/dev/ttys003"),
        ] + ScriptedTerminalRoute.iterm.open(pid: 10, ttys: ["/dev/ttys003"]))
    }

    @Test func tmuxWithNoClientAttachedHasNothingToShowItIn() {
        #expect(TerminalRoutes.plan(agent: 70, facts: tmuxFacts(clients: "")) == [.layer(.unresolved("tmux"))])
    }

    private static let zellij = "/opt/homebrew/bin/zellij"
    private static let zellijSocket = "/var/folders/T/zellij-501/contract_version_1/work"

    private func zellijFacts(clients: [Int] = [80], pane: String? = "2") -> Facts {
        var environment: [String: String] = [:]
        environment["ZELLIJ_PANE_ID"] = pane
        let facts = Facts()
            .add(90, parent: 85, tty: "/dev/ttys040", ["claude"], environment: environment)
            .add(85, parent: 84, tty: "/dev/ttys040", ["/bin/zsh"])
            .add(84, parent: 1, [Self.zellij, "--server", Self.zellijSocket])
            .add(80, parent: 20, tty: "/dev/ttys041", ["zellij", "-s", "work"], executable: Self.zellij)
            .add(81, parent: 21, tty: "/dev/ttys042", ["zellij", "attach", "work"], executable: Self.zellij)
            .add(20, parent: 10, tty: "/dev/ttys041", ["/usr/bin/login"])
            .add(21, parent: 10, tty: "/dev/ttys042", ["/usr/bin/login"])
            .add(10, parent: 1, ["ghostty"], app: Self.ghostty)
        var lsof = "p84\nf5\nd0xlisten\nn\(Self.zellijSocket)\n"
        for (index, client) in clients.enumerated() {
            lsof += "f\(6 + index)\nd0xaccepted\(index)\nn\(Self.zellijSocket)\n"
            lsof += "p\(client)\nf5\nd0xclient\(index)\nn->0xaccepted\(index)\np84\n"
        }
        lsof += "p99\nf5\nd0xstranger\nn->0xelsewhere\n"
        facts.outputs[["/usr/sbin/lsof", "-U", "-a", "-c", "zellij", "-F", "pdn"]] = lsof
        facts.owners["/var/folders/T/zellij-501/contract_version_1"] = ["work": 84]
        facts.outputs[[Self.zellij, "--session", "work", "action", "list-panes", "-t", "-j"]] = #"""
            [{"id":0,"is_plugin":true,"tab_id":0,"is_floating":false,"is_suppressed":false,"is_selectable":true},
             {"id":0,"is_plugin":false,"tab_id":0,"is_floating":false,"is_suppressed":false,"is_selectable":true},
             {"id":2,"is_plugin":true,"tab_id":5,"is_floating":false,"is_suppressed":false,"is_selectable":false},
             {"id":2,"is_plugin":false,"tab_id":5,"is_floating":false,"is_suppressed":false,"is_selectable":true},
             {"id":3,"is_plugin":false,"tab_id":5,"is_floating":false,"is_suppressed":false,"is_selectable":true},
             {"id":4,"is_plugin":true,"tab_id":5,"is_floating":false,"is_suppressed":false,"is_selectable":true},
             {"id":5,"is_plugin":false,"tab_id":5,"is_floating":true,"is_suppressed":false,"is_selectable":true},
             {"id":6,"is_plugin":false,"tab_id":5,"is_floating":false,"is_suppressed":true,"is_selectable":true}]
            """#
        return facts
    }

    private static func zellijLayer(session: String = "work", confirmed: Bool = true) -> OpenAction {
        let action = [zellij, "--session", session, "action"]
        return .layer(PaneLayer("Zellij", commands: [
            PaneCommand(action + ["go-to-tab-by-id", "5"]),
            PaneCommand(action + ["hide-floating-panes", "-t", "5"], accepting: [0, 2]),
            PaneCommand(action + ["focus-next-pane"], until: FocusWalk(check: action + ["list-clients"], pane: "terminal_2", steps: 2)),
        ], confirmed: confirmed))
    }

    @Test func anAgentInZellijSelectsItsTabAndPaneThenTheTerminalItsClientRunsIn() {
        #expect(TerminalRoutes.plan(agent: 90, facts: zellijFacts()) == [
            Self.zellijLayer(),
        ] + ScriptedTerminalRoute.ghostty.open(pid: 10, ttys: ["/dev/ttys041"]))
    }

    @Test func aZellijPaneTheAgentReportedOpensThoughItsEnvironmentCannotBeRead() {
        let facts = zellijFacts(pane: nil).reporting(["ZELLIJ_PANE_ID": "2"], for: 90)
        #expect(TerminalRoutes.plan(agent: 90, facts: facts) == [
            Self.zellijLayer(),
        ] + ScriptedTerminalRoute.ghostty.open(pid: 10, ttys: ["/dev/ttys041"]))
    }

    @Test func aRenamedZellijSessionIsOpenedUnderItsNewName() {
        let facts = zellijFacts()
        facts.owners["/var/folders/T/zellij-501/contract_version_1"] = ["renamed": 84, "work": 184]
        facts.outputs[[Self.zellij, "--session", "renamed", "action", "list-panes", "-t", "-j"]] =
            facts.outputs[[Self.zellij, "--session", "work", "action", "list-panes", "-t", "-j"]]
        #expect(TerminalRoutes.plan(agent: 90, facts: facts).first == Self.zellijLayer(session: "renamed"))
    }

    @Test func aZellijSessionInSeveralWindowsCannotConfirmWhichOneItMovedFocusIn() {
        #expect(TerminalRoutes.plan(agent: 90, facts: zellijFacts(clients: [81, 80])) == [
            Self.zellijLayer(confirmed: false),
        ] + ScriptedTerminalRoute.ghostty.open(pid: 10, ttys: ["/dev/ttys041"]))
    }

    @Test func aZellijPaneItsSessionDoesNotListIsUnresolved() {
        #expect(TerminalRoutes.plan(agent: 90, facts: zellijFacts(pane: "7")).first == .layer(.unresolved("Zellij")))
        #expect(TerminalRoutes.plan(agent: 90, facts: zellijFacts(pane: nil)).first == .layer(.unresolved("Zellij")))
    }

    @Test func aZellijPaneThatCannotBeReachedByStepppingThroughTiledPanesIsUnresolved() {
        for pane in ["5", "6"] {
            #expect(TerminalRoutes.plan(agent: 90, facts: zellijFacts(pane: pane)).first == .layer(.unresolved("Zellij")))
        }
    }

    @Test func aZellijPaneListWithoutPaneStateIsUnresolved() {
        let facts = zellijFacts()
        facts.outputs[[Self.zellij, "--session", "work", "action", "list-panes", "-t", "-j"]] =
            #"[{"id":2,"is_plugin":false,"tab_id":5}]"#
        #expect(TerminalRoutes.plan(agent: 90, facts: facts).first == .layer(.unresolved("Zellij")))
    }

    @Test func aZellijFocusWalkIsDoneOnlyWhenAWindowShowsTheTargetPaneAndUnknownWhenTheWindowsCannotBeRead() {
        let walk = FocusWalk(check: ["list-clients"], pane: "terminal_2", steps: 1)
        #expect(walk.reached((0, "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n1         terminal_2     claude\n")) == true)
        #expect(walk.reached((0, "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n1         terminal_20    claude terminal_2\n")) == false)
        #expect(walk.reached((1, "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n1         terminal_2     claude\n")) == nil)
        #expect(walk.reached((0, "")) == nil)
    }

    @Test func aZellijSessionWithNoWindowHasNothingToShowItIn() {
        #expect(TerminalRoutes.plan(agent: 90, facts: zellijFacts(clients: [])) == [Self.zellijLayer()])
    }

    @Test func aScriptedTerminalLooksForEveryTtyItWasGivenAndThenComesForward() throws {
        let actions = ScriptedTerminalRoute.iterm.open(pid: 10, ttys: ["/dev/ttys058", "/dev/ttys\"060"])
        guard case .select(.script(let app, let pid, let body)) = try #require(actions.first) else {
            Issue.record("expected a script")
            return
        }
        #expect(app == "com.googlecode.iterm2" && pid == 10)
        #expect(body.hasPrefix(#"set wanted to {"/dev/ttys058", "/dev/ttys\"060"}"#))
        #expect(actions.last == .activate(app: "com.googlecode.iterm2", pid: 10))
        #expect(ScriptedTerminalRoute.ghostty.open(pid: 10, ttys: []) == [.activate(app: "com.mitchellh.ghostty", pid: 10)])
    }

    @Test func aPlanNamesItsTerminalAppAndItsMultiplexersOutermostFirst() {
        let actions = [Self.zellijLayer(), Self.herdrLayer()] + ScriptedTerminalRoute.ghostty.open(pid: 10, ttys: ["/dev/ttys000"])
        let layers = TerminalRoutes.layers(of: actions)
        #expect(layers.app == "com.mitchellh.ghostty")
        #expect(layers.multiplexers == ["herdr", "Zellij"])
        #expect(TerminalRoutes.layers(of: []).app == nil)
    }

    @Test func onlyTheEnvironmentOpenAndTheFrontCheckReadIsKept() {
        #expect(TerminalRoutes.environmentKeys == [
            "HERDR_SOCKET_PATH", "HERDR_PANE_ID", "TMUX", "ZELLIJ_PANE_ID", "WARP_FOCUS_URL", "CMUX_SURFACE_ID",
        ])
    }
}
