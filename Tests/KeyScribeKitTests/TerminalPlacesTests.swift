import Foundation
import Testing
@testable import KeyScribeKit

struct TerminalPlacesTests {
    typealias Facts = TerminalRoutesTests.Facts
    private static let tmux = "/opt/homebrew/bin/tmux"
    private static let tmuxSocket = "/private/tmp/tmux-501/default"
    private static let ghostty = "com.mitchellh.ghostty"
    private static let format = "#{pane_tty}\t#{pane_id}\t#{session_name}\t#{window_id}\t#{window_name}\t#{automatic-rename}\t#{status}\t#{allow-rename}"

    private func tmuxFacts(
        window: String = "backend", automatic: String = "0", session: String = "work", status: String = "on", allowRename: String = "0"
    ) -> Facts {
        let facts = Facts()
            .add(70, parent: 65, tty: "/dev/ttys012", ["claude"], environment: ["TMUX": "\(Self.tmuxSocket),60,0"])
            .add(65, parent: 60, tty: "/dev/ttys012", ["-zsh"])
            .add(60, parent: 1, ["tmux", "new", "-s", "work"], executable: Self.tmux)
            .add(55, parent: 50, tty: "/dev/ttys003", ["tmux", "attach"], executable: Self.tmux)
            .add(50, parent: 10, tty: "/dev/ttys003", ["-zsh"])
            .add(10, parent: 1, ["ghostty"], app: Self.ghostty)
        let tmux = [Self.tmux, "-S", Self.tmuxSocket]
        facts.outputs[tmux + ["list-panes", "-a", "-F", Self.format]] =
            "/dev/ttys011\t%1\tother\t@1\tzsh\t1\ton\t0\n/dev/ttys012\t%4\t\(session)\t@3\t\(window)\t\(automatic)\t\(status)\t\(allowRename)\n"
        facts.outputs[tmux + ["list-clients", "-F", "#{client_tty}\t#{client_pid}\t#{client_session}\t#{client_activity}"]] =
            "/dev/ttys003\t55\t\(session)\t900\n"
        return facts
    }

    private func labels(_ walk: TerminalPlaceWalk?) -> [String] {
        (walk?.layers ?? []).flatMap(\.labels).map { "\($0.surface ?? "?") \($0.word) \($0.text)" }
    }

    @Test func aWindowAndSessionTheUserNamedInTmuxNameThePlaceAndTheWalkGoesOnToTheTerminal() {
        let walk = TerminalPlaces.walk(agent: 70, facts: tmuxFacts())
        #expect(labels(walk) == ["tmux window backend", "tmux session work"])
        #expect(walk?.layers.first?.labels.map(\.level) == [.tab, .workspace])
        #expect(walk?.layers.first?.containers == [
            "tmux:\(Self.tmuxSocket)#pane:%4", "tmux:\(Self.tmuxSocket)#window:@3", "tmux:\(Self.tmuxSocket)#session:work",
        ])
        #expect(walk?.host == TerminalHost(route: "Ghostty", app: Self.ghostty, pid: 10, ttys: ["/dev/ttys003"]))
        #expect(walk?.surface == "tmux")
    }

    @Test func aWindowTmuxNamesAfterItsProgramANumberedSessionAndAHiddenStatusLineGiveNoName() {
        #expect(labels(TerminalPlaces.walk(agent: 70, facts: tmuxFacts(window: "node", automatic: "1", session: "3"))).isEmpty)
        #expect(labels(TerminalPlaces.walk(agent: 70, facts: tmuxFacts(status: "off"))).isEmpty)
    }

    @Test func aWindowNameAProgramMaySetIsNotANameWhileTmuxAllowsRenaming() {
        #expect(labels(TerminalPlaces.walk(agent: 70, facts: tmuxFacts(window: "claude task", allowRename: "1"))) == ["tmux session work"])
    }

    @Test func aPaneTmuxCannotFindLeavesThePlaceUnresolved() {
        let facts = tmuxFacts()
        facts.outputs[[Self.tmux, "-S", Self.tmuxSocket, "list-panes", "-a", "-F", Self.format]] = ""
        #expect(TerminalPlaces.walk(agent: 70, facts: facts)?.layers == [PlaceLayer(unresolved: true)])
    }

    @Test func anUnreadableAgentProcessIsNoWalk() {
        #expect(TerminalPlaces.walk(agent: 999, facts: tmuxFacts()) == nil)
    }

    @Test func anAgentInsideHerdrLeavesHerdrToItsReaderAndGoesOnToTheTerminalAroundIt() {
        let herdr = "/opt/homebrew/bin/herdr"
        let socket = "/Users/me/.config/herdr/herdr.sock"
        let facts = Facts()
            .add(50, parent: 45, tty: "/dev/ttys007", ["claude"], environment: ["HERDR_SOCKET_PATH": socket, "HERDR_PANE_ID": "w1:p2"])
            .add(45, parent: 40, tty: "/dev/ttys007", ["-zsh"])
            .add(40, parent: 1, [herdr, "server"])
            .add(35, parent: 20, tty: "/dev/ttys000", [herdr])
            .add(20, parent: 10, tty: "/dev/ttys000", ["/usr/bin/login"])
            .add(10, parent: 1, ["ghostty"], app: Self.ghostty)
        facts.outputs[[herdr, "session", "list", "--json"]] = #"{"sessions":[{"name":"default","socket_path":"\#(socket)"}]}"#
        let walk = TerminalPlaces.walk(agent: 50, facts: facts)
        #expect(walk?.layers == [])
        #expect(walk?.host == TerminalHost(route: "Ghostty", app: Self.ghostty, pid: 10, ttys: ["/dev/ttys000"]))
    }

    private static let zellij = "/opt/homebrew/bin/zellij"
    private static let zellijSocket = "/var/folders/T/zellij-501/contract_version_1/work"

    private func zellijFacts(tab: String) -> Facts {
        let facts = Facts()
            .add(90, parent: 85, tty: "/dev/ttys040", ["claude"], environment: ["ZELLIJ_PANE_ID": "2"])
            .add(85, parent: 84, tty: "/dev/ttys040", ["/bin/zsh"])
            .add(84, parent: 1, [Self.zellij, "--server", Self.zellijSocket])
        facts.owners["/var/folders/T/zellij-501/contract_version_1"] = ["work": 84]
        facts.outputs[["/usr/sbin/lsof", "-U", "-a", "-c", "zellij", "-F", "pdn"]] = "p84\nf5\nd0xlisten\nn\(Self.zellijSocket)\n"
        facts.outputs[[Self.zellij, "--session", "work", "action", "list-panes", "-t", "-j"]] = """
            [{"id":2,"is_plugin":true,"tab_id":0,"title":"zellij:tab-bar","tab_name":"Tab #1"},
             {"id":2,"is_plugin":false,"tab_id":5,"title":"✳ Refactor auth middleware","tab_name":"\(tab)"}]
            """
        return facts
    }

    @Test func aZellijTabTheUserNamedNamesThePlaceButThePaneTitleAProgramWritesNeverDoes() {
        let walk = TerminalPlaces.walk(agent: 90, facts: zellijFacts(tab: "backend"))
        #expect(labels(walk) == ["Zellij tab backend"])
        #expect(walk?.layers.first?.containers == ["zellij:\(Self.zellijSocket)#pane:2", "zellij:\(Self.zellijSocket)#tab:5"])
        #expect(labels(TerminalPlaces.walk(agent: 90, facts: zellijFacts(tab: "Tab #3"))).isEmpty)
    }

    @Test func eachServerIsAskedOnceForEveryConversationInARead() {
        let facts = tmuxFacts()
        facts.add(71, parent: 66, tty: "/dev/ttys011", ["claude"], environment: ["TMUX": "\(Self.tmuxSocket),60,0"])
            .add(66, parent: 60, tty: "/dev/ttys011", ["-zsh"])
        let cached = CachedTerminalFacts(facts)
        _ = TerminalPlaces.walk(agent: 70, facts: cached)
        _ = TerminalPlaces.walk(agent: 71, facts: cached)
        #expect(facts.ran.filter { $0.contains("list-panes") }.count == 1)
    }
}

struct TerminalHostPlacesTests {
    @Test func ghosttyNamesATerminalByItsOverrideAndItsTabOnlyInAWindowWithoutSplits() {
        let answer = """
            W\tw1\t2\t2
            T\ttab-a\tPayments\t/dev/ttys004
            T\ttab-b\t\t/dev/ttys009
            S\tterm-a\t/dev/ttys004\tArchitect
            S\tterm-b\t/dev/ttys009\t
            W\tw2\t1\t2
            T\ttab-c\tSplit\t/dev/ttys020
            S\tterm-c\t/dev/ttys020\t
            S\tterm-d\t/dev/ttys021\tTests
            """
        let route = ScriptedTerminalRoute.ghostty
        let first = route.places(answer: answer, ttys: ["/dev/ttys004"])
        #expect(first?.labels.map(\.text) == ["Architect", "Payments"])
        #expect(first?.labels.map(\.level) == [.pane, .tab])
        #expect(first?.containers == ["ghostty#terminal:term-a", "ghostty#tab:tab-a"])
        #expect(route.places(answer: answer, ttys: ["/dev/ttys009"])?.labels == [])
        #expect(route.places(answer: answer, ttys: ["/dev/ttys021"])?.labels.map(\.text) == ["Tests"])
        #expect(route.places(answer: answer, ttys: ["/dev/ttys020"])?.containers == ["ghostty#terminal:term-c"])
        #expect(route.places(answer: answer, ttys: ["/dev/ttys099"]) == nil)
    }

    @Test func iTermNamesATabOnlyByTheTitleTheUserSet() {
        let answer = "7\t1\t/dev/ttys004\tPayments\n7\t2\t/dev/ttys005\t\n"
        let route = ScriptedTerminalRoute.iterm
        #expect(route.places(answer: answer, ttys: ["/dev/ttys004"])?.labels.map(\.text) == ["Payments"])
        #expect(route.places(answer: answer, ttys: ["/dev/ttys004"])?.containers == ["iterm#tab:7:1"])
        #expect(route.places(answer: answer, ttys: ["/dev/ttys005"])?.labels == [])
    }

    @Test func terminalAppHasNoNameItCanProveTheUserSet() {
        #expect(ScriptedTerminalRoute.terminal.placeScript == nil)
    }
}
