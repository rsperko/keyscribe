import Foundation
import Testing
@testable import KeyScribeKit

struct TerminalTitlesTests {
    typealias Facts = TerminalRoutesTests.Facts

    private static let routes = ResolvedSurfaces.builtIn.routes
    private static let ghostty = "com.mitchellh.ghostty"
    private static let tmux = "/opt/homebrew/bin/tmux"
    private static let tmuxSocket = "/private/tmp/tmux-501/default"
    private static let codexTitle = "codex 019a3c5e-7d21-7f40-9b8e-41c2d7a0e6f1"

    private func route(_ name: String) throws -> any Route {
        try #require(ResolvedSurfaces.builtIn.route(named: name))
    }

    private func read(_ pid: Int, _ facts: Facts) -> TitleRead? {
        TerminalTitles.read(agent: pid, facts: facts, routes: Self.routes)
    }

    private func ghosttyFacts() -> Facts {
        Facts()
            .add(10, parent: 1, ["ghostty"], app: Self.ghostty)
            .add(20, parent: 10, tty: "/dev/ttys004", ["/usr/bin/login"])
            .add(30, parent: 20, tty: "/dev/ttys004", ["codex"])
    }

    @Test func anAgentDirectlyInATerminalAppIsReadByOneScriptMatchedByItsTTY() throws {
        let read = try #require(read(30, ghosttyFacts()))
        let ghostty = try route("Ghostty") as! ScriptedTerminalRoute
        #expect(read == TitleRead(
            route: "Ghostty", source: .script(app: Self.ghostty, pid: 10, body: try #require(ghostty.titleScript)), pane: ["/dev/ttys004"]))
    }

    @Test func theInnermostMultiplexerPaneIsReadNotTheTerminalTabAroundIt() throws {
        let facts = ghosttyFacts()
            .add(60, parent: 1, ["tmux", "new", "-s", "work"], executable: Self.tmux)
            .add(65, parent: 60, tty: "/dev/ttys012", ["-zsh"])
            .add(70, parent: 65, tty: "/dev/ttys012", ["codex"], environment: ["TMUX": "\(Self.tmuxSocket),60,0"])
        #expect(read(70, facts) == TitleRead(
            route: "tmux",
            source: .command([Self.tmux, "-S", Self.tmuxSocket, "list-panes", "-a", "-F", "#{pane_tty}\t#{pane_title}"]),
            pane: ["/dev/ttys012"]))
        #expect(facts.ran.isEmpty)
    }

    @Test func aMultiplexerThatCannotPlaceThePaneGivesNoReadRatherThanTheOuterTab() {
        let facts = ghosttyFacts()
            .add(60, parent: 1, ["tmux", "new"], executable: Self.tmux)
            .add(70, parent: 60, tty: "/dev/ttys012", ["codex"])
        #expect(read(70, facts) == nil)
        #expect(read(999, facts) == nil)
    }

    @Test func aWarpTabHasNoTitleRead() {
        let facts = Facts()
            .add(10, parent: 1, ["/Applications/Warp.app/Contents/MacOS/stable"], app: "dev.warp.Warp-Stable")
            .add(30, parent: 10, tty: "/dev/ttys004", ["codex"], environment: ["WARP_FOCUS_URL": "warp://session/1"])
        #expect(read(30, facts) == nil)
    }

    @Test func tmuxNamesThePaneByItsTTY() throws {
        let answer = "/dev/ttys011\tMacBook-Pro.local\n/dev/ttys012\t\(Self.codexTitle)\n"
        #expect(try route("tmux").title(answer: answer, pane: ["/dev/ttys012"]) == Self.codexTitle)
        #expect(try route("tmux").title(answer: answer, pane: ["/dev/ttys099"]) == nil)
        #expect(try route("tmux").title(answer: "/dev/ttys012\t  \n", pane: ["/dev/ttys012"]) == nil)
    }

    @Test func zellijReadsTheSessionsPaneListAndSkipsPlugins() throws {
        let socket = "/var/folders/T/zellij-501/contract_version_1/work"
        let zellij = "/opt/homebrew/bin/zellij"
        let facts = Facts()
            .add(84, parent: 1, [zellij, "--server", socket])
            .add(85, parent: 84, tty: "/dev/ttys040", ["/bin/zsh"])
            .add(90, parent: 85, tty: "/dev/ttys040", ["codex"], environment: ["ZELLIJ_PANE_ID": "2"])
        facts.owners["/var/folders/T/zellij-501/contract_version_1"] = ["work": 84]
        #expect(read(90, facts) == TitleRead(
            route: "Zellij", source: .command([zellij, "--session", "work", "action", "list-panes", "-t", "-j"]), pane: ["2"]))
        let answer = """
            [{"id":2,"is_plugin":true,"tab_id":0,"title":"zellij:tab-bar","tab_name":"Tab #1"},
             {"id":2,"is_plugin":false,"tab_id":5,"title":"\(Self.codexTitle)","tab_name":"backend"}]
            """
        #expect(try route("Zellij").title(answer: answer, pane: ["2"]) == Self.codexTitle)
        #expect(try route("Zellij").title(answer: "not json", pane: ["2"]) == nil)
    }

    @Test func herdrReadsTheTerminalTitleOfTheAgentsPane() throws {
        let herdr = "/opt/homebrew/bin/herdr"
        let socket = "/Users/me/.config/herdr/herdr.sock"
        let facts = Facts()
            .add(40, parent: 1, [herdr, "server"])
            .add(45, parent: 40, tty: "/dev/ttys007", ["-zsh"])
            .add(50, parent: 45, tty: "/dev/ttys007", ["codex"], environment: ["HERDR_SOCKET_PATH": socket, "HERDR_PANE_ID": "w1:p2"])
        #expect(read(50, facts) == TitleRead(
            route: "herdr", source: .command(["/usr/bin/env", "-u", "HERDR_PANE_ID", "HERDR_SOCKET_PATH=\(socket)", herdr, "pane", "list"]),
            pane: ["w1:p2"]))
        let answer = """
            {"id":"cli:pane:list","result":{"panes":[\
            {"agent":"claude","cwd":"/Users/me","focused":false,"pane_id":"w1:p1","tab_id":"w1:t1",\
            "terminal_id":"term_65f232b5b969a1","terminal_title":"✳ Keyscribe main branch","workspace_id":"w1"},\
            {"cwd":"/Users/me","focused":true,"pane_id":"w1:p2","tab_id":"w1:t1","terminal_id":"term_7a1",\
            "terminal_title":"\(Self.codexTitle)","terminal_title_stripped":"\(Self.codexTitle)","workspace_id":"w1"}]}}
            """
        #expect(try route("herdr").title(answer: answer, pane: ["w1:p2"]) == Self.codexTitle)
        #expect(try route("herdr").title(answer: answer, pane: ["w1:p9"]) == nil)
    }

    @Test func rexAsksTheAgentsBlockForTheTitleAProgramLastSet() throws {
        let rex = "/Users/me/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
        let server = "unix:///Users/me/Library/Application%20Support/rex/server.sock"
        let session = "session:01a1d831-b348-79db-973e-25979abf81e3"
        let block = "block:01a1d831-b349-7a7d-8e83-0b7f28690c7b"
        let facts = Facts()
            .add(40, parent: 1, [rex, "server", "run", "--listen", server], executable: rex)
            .add(50, parent: 40, tty: "/dev/ttys007", ["codex"], environment: ["REX_SERVER": server, "REX_SESSION": session, "REX_BLOCK": block])
        #expect(read(50, facts) == TitleRead(
            route: "Rex", source: .command([rex, "--autostart=false", "-S", server, "block", "call", "-s", session, "-b", block, "title"]),
            pane: []))
        #expect(try route("Rex").title(answer: #"{"title":"\#(Self.codexTitle)","owner":{"pid":77938,"name":"codex"}}"#, pane: [])
            == Self.codexTitle)
        #expect(try route("Rex").title(answer: #"{"title":""}"#, pane: []) == nil)
    }

    @Test func weztermListsItsPanesOnceAndMatchesTheAgentsTTY() throws {
        let wezterm = "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui"
        let socket = "/Users/me/.local/share/wezterm/gui-sock-10"
        let facts = Facts()
            .add(10, parent: 1, [wezterm], app: "com.github.wez.wezterm")
            .add(30, parent: 10, tty: "/dev/ttys036", ["codex"], environment: ["WEZTERM_PANE": "1", "WEZTERM_UNIX_SOCKET": socket])
        facts.listening[10] = [socket]
        let cli = ["/usr/bin/env", "WEZTERM_UNIX_SOCKET=\(socket)", "/Applications/WezTerm.app/Contents/MacOS/wezterm", "cli", "--no-auto-start"]
        #expect(read(30, facts) == TitleRead(route: "WezTerm", source: .command(cli + ["list", "--format", "json"]), pane: ["1", "/dev/ttys036"]))
        let answer = """
            [{"window_id":0,"tab_id":0,"pane_id":0,"workspace":"default","title":"zsh","is_active":true,"tty_name":"/dev/ttys035"},
             {"window_id":0,"tab_id":1,"pane_id":1,"workspace":"default","title":"\(Self.codexTitle)","is_active":true,"tty_name":"/dev/ttys036"}]
            """
        #expect(try route("WezTerm").title(answer: answer, pane: ["1", "/dev/ttys036"]) == Self.codexTitle)
        let muxed = #"[{"pane_id":4,"title":"zsh","tty_name":null},{"pane_id":5,"title":"\#(Self.codexTitle)","tty_name":null}]"#
        #expect(try route("WezTerm").title(answer: muxed, pane: ["5", "/dev/ttys036"]) == Self.codexTitle)
        facts.listening[10] = []
        #expect(read(30, facts) == nil)
    }

    @Test func kittyListsItsWindowsOnceAndMatchesTheAgentsWindowID() throws {
        let socket = "/tmp/kitty-10"
        let facts = Facts()
            .add(10, parent: 1, ["/Applications/kitty.app/Contents/MacOS/kitty"], app: "net.kovidgoyal.kitty")
            .add(30, parent: 10, tty: "/dev/ttys036", ["codex"], environment: ["KITTY_WINDOW_ID": "2", "KITTY_LISTEN_ON": "unix:\(socket)"])
        facts.listening[10] = [socket]
        #expect(read(30, facts) == TitleRead(
            route: "kitty", source: .command(["/Applications/kitty.app/Contents/MacOS/kitten", "@", "--to", "unix:\(socket)", "ls"]),
            pane: ["2", "/dev/ttys036"]))
        let answer = """
            [{"id":1,"is_active":true,"is_focused":true,"tabs":[{"id":1,"is_active":true,"title":"zsh","windows":[\
            {"id":1,"pid":20,"is_focused":false,"title":"zsh","foreground_processes":[{"pid":20,"cmdline":["-zsh"]}]},\
            {"id":2,"pid":21,"is_focused":true,"title":"\(Self.codexTitle)","foreground_processes":[{"pid":30,"cmdline":["codex"]}]}]}]}]
            """
        #expect(try route("kitty").title(answer: answer, pane: ["2", "/dev/ttys036"]) == Self.codexTitle)
        #expect(try route("kitty").title(answer: answer, pane: ["7"]) == nil)
    }

    @Test func ghosttyReadsTheTerminalNameUnlessItIsOnlyTheUsersOverride() throws {
        let answer = "/dev/ttys003\t\tzsh\n/dev/ttys004\t\t\(Self.codexTitle)\n/dev/ttys005\tArchitect\tArchitect\n"
        #expect(try route("Ghostty").title(answer: answer, pane: ["/dev/ttys004"]) == Self.codexTitle)
        #expect(try route("Ghostty").title(answer: answer, pane: ["/dev/ttys005"]) == nil)
    }

    @Test func itermAndTerminalMatchTheSessionOrTabByTTY() throws {
        let answer = "/dev/ttys001\t\n/dev/ttys002\t\(Self.codexTitle)\n"
        #expect(try route("iTerm").title(answer: answer, pane: ["/dev/ttys002"]) == Self.codexTitle)
        #expect(try route("iTerm").title(answer: answer, pane: ["/dev/ttys001"]) == nil)
        #expect(try route("Terminal").title(answer: answer, pane: ["/dev/ttys002"]) == Self.codexTitle)
    }

    @Test func cmuxMatchesTheTerminalBySurfaceID() throws {
        let surface = "6F1C2B3A-4D5E-4F60-8A7B-9C0D1E2F3A4B"
        let facts = Facts()
            .add(10, parent: 1, ["/Applications/cmux.app/Contents/MacOS/cmux"], app: "com.cmuxterm.app")
            .add(30, parent: 10, tty: "/dev/ttys004", ["codex"], environment: ["CMUX_SURFACE_ID": surface])
        let read = try #require(read(30, facts))
        #expect(read.pane == [surface])
        guard case .script(let app, let pid, _) = read.source else {
            Issue.record("expected a script")
            return
        }
        #expect(app == "com.cmuxterm.app" && pid == 10)
        let answer = "AAAA-0000\tzsh\n\(surface)\t\(Self.codexTitle)\n"
        #expect(try route("cmux").title(answer: answer, pane: [surface]) == Self.codexTitle)
    }

    @Test func titlesThatSpanTabsKeepThemAndTheTitleReadLeavesThePlaceWalkAlone() throws {
        #expect(TerminalTitles.keyed("/dev/ttys004\ta\tb\n", among: ["/dev/ttys004"]) == "a\tb")
        let facts = ghosttyFacts()
        let before = TerminalPlaces.walk(agent: 30, facts: facts)
        _ = read(30, facts)
        #expect(TerminalPlaces.walk(agent: 30, facts: facts) == before)
    }
}
