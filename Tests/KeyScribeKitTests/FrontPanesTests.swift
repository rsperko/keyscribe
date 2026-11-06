import Foundation
import Testing
@testable import KeyScribeKit

struct FrontPanesTests {
    typealias Facts = TerminalRoutesTests.Facts

    private static let ghostty = "com.mitchellh.ghostty"
    private static let herdr = "/opt/homebrew/bin/herdr"
    private static let tmux = "/opt/homebrew/bin/tmux"
    private static let socket = "/Users/me/.config/herdr/herdr.sock"
    private static let sessions = #"{"sessions":[{"name":"default","socket_path":"/Users/me/.config/herdr/herdr.sock"},{"name":"work","socket_path":"/Users/me/.config/herdr/work.sock"}]}"#

    private static func herdrCommand(on socket: String = socket, _ arguments: String...) -> [String] {
        ["/usr/bin/env", "-u", "HERDR_PANE_ID", "HERDR_SOCKET_PATH=\(socket)", herdr] + arguments
    }

    private static func panes(_ rows: (String, Bool)...) -> String {
        let items = rows.map { #"{"pane_id":"\#($0.0)","focused":\#($0.1)}"# }.joined(separator: ",")
        return #"{"result":{"panes":[\#(items)]}}"#
    }

    private static func processInfo(shell: Int) -> String {
        #"{"result":{"process_info":{"shell_pid":\#(shell),"foreground_processes":[]}}}"#
    }

    private static func front(_ tty: String?) -> TerminalFront { TerminalFront(app: ghostty, tty: tty) }

    private static func herdrSetup() -> Facts {
        let facts = Facts()
            .add(10, parent: 1, ["ghostty"], app: ghostty)
            .add(11, parent: 10, tty: "/dev/ttys000", ["-zsh"])
            .add(12, parent: 11, tty: "/dev/ttys000", ["herdr"], executable: herdr)
            .add(20, parent: 1, ["herdr", "server"], executable: herdr)
            .add(21, parent: 20, tty: "/dev/ttys007", ["-zsh"])
            .add(22, parent: 21, tty: "/dev/ttys007", ["claude"])
            .add(31, parent: 20, tty: "/dev/ttys009", ["-zsh"])
            .add(32, parent: 31, tty: "/dev/ttys009", ["pi"])
        facts.outputs[[herdr, "session", "list", "--json"]] = sessions
        facts.outputs[herdrCommand("pane", "process-info", "--pane", "w1:p2")] = processInfo(shell: 21)
        facts.outputs[herdrCommand("pane", "process-info", "--pane", "w2:p1")] = processInfo(shell: 31)
        return facts
    }

    @Test func aPlainTerminalTabIsThePaneItShows() {
        let facts = Facts()
            .add(10, parent: 1, ["ghostty"], app: Self.ghostty)
            .add(20, parent: 10, tty: "/dev/ttys004", ["/usr/bin/login"])
            .add(30, parent: 20, tty: "/dev/ttys004", ["claude"])
        let reading = FrontPanes.read(Self.front("/dev/ttys004"), facts: facts)
        #expect(reading == .pane(FrontPane(app: Self.ghostty, tty: "/dev/ttys004", multiplexers: [])))
        #expect(reading.check(agent: 30, facts: facts) == .shown)
    }

    @Test func anAgentInAnotherTabIsNotShown() {
        let facts = Facts()
            .add(10, parent: 1, ["ghostty"], app: Self.ghostty)
            .add(30, parent: 10, tty: "/dev/ttys004", ["claude"])
            .add(40, parent: 10, tty: "/dev/ttys005", ["pi"])
        let reading = FrontPanes.read(Self.front("/dev/ttys005"), facts: facts)
        #expect(reading.check(agent: 30, facts: facts) == .elsewhere)
        #expect(reading.check(agent: 40, facts: facts) == .shown)
    }

    @Test func aWrapperPtyStillShowsTheAgentItWraps() {
        let facts = Facts()
            .add(10, parent: 1, ["ghostty"], app: Self.ghostty)
            .add(20, parent: 10, tty: "/dev/ttys058", ["/usr/bin/login"])
            .add(30, parent: 20, tty: "/dev/ttys058", ["python3", "ptywrap.py"])
            .add(40, parent: 30, tty: "/dev/ttys060", ["claude"])
        #expect(FrontPanes.read(Self.front("/dev/ttys058"), facts: facts).check(agent: 40, facts: facts) == .shown)
    }

    @Test func herdrsFocusedPaneIsWhatTheTerminalShows() {
        let facts = Self.herdrSetup()
        facts.outputs[Self.herdrCommand("pane", "list")] = Self.panes(("w1:p2", true), ("w2:p1", false))
        let reading = FrontPanes.read(Self.front("/dev/ttys000"), facts: facts)
        #expect(reading == .pane(FrontPane(app: Self.ghostty, tty: "/dev/ttys007", multiplexers: ["herdr"])))
        #expect(reading.check(agent: 22, facts: facts) == .shown)
        #expect(reading.check(agent: 32, facts: facts) == .elsewhere)
    }

    @Test func anAgentInAnUnfocusedHerdrPaneIsNotShown() {
        let facts = Self.herdrSetup()
        facts.outputs[Self.herdrCommand("pane", "list")] = Self.panes(("w1:p2", false), ("w2:p1", true))
        let reading = FrontPanes.read(Self.front("/dev/ttys000"), facts: facts)
        #expect(reading.check(agent: 22, facts: facts) == .elsewhere)
        #expect(reading.check(agent: 32, facts: facts) == .shown)
    }

    @Test func herdrSessionsAreReadThroughTheClientsOwnSocket() {
        let facts = Self.herdrSetup()
        facts.add(12, parent: 11, tty: "/dev/ttys000", ["herdr", "--session", "work"], executable: Self.herdr)
        let work = "/Users/me/.config/herdr/work.sock"
        facts.outputs[Self.herdrCommand(on: work, "pane", "list")] = Self.panes(("w2:p1", true))
        facts.outputs[Self.herdrCommand(on: work, "pane", "process-info", "--pane", "w2:p1")] = Self.processInfo(shell: 31)
        #expect(FrontPanes.read(Self.front("/dev/ttys000"), facts: facts).check(agent: 32, facts: facts) == .shown)
    }

    @Test func herdrWithoutExactlyOneFocusedPaneIsUnknown() {
        let facts = Self.herdrSetup()
        facts.outputs[Self.herdrCommand("pane", "list")] = Self.panes(("w1:p2", true), ("w2:p1", true))
        #expect(FrontPanes.read(Self.front("/dev/ttys000"), facts: facts) == .unknown(.multiplexer("herdr")))
        facts.outputs[Self.herdrCommand("pane", "list")] = Self.panes(("w1:p2", false))
        #expect(FrontPanes.read(Self.front("/dev/ttys000"), facts: facts) == .unknown(.multiplexer("herdr")))
    }

    @Test func aHerdrThatCannotBeReadIsUnknownNotThePlainTab() {
        let facts = Self.herdrSetup()
        let reading = FrontPanes.read(Self.front("/dev/ttys000"), facts: facts)
        #expect(reading == .unknown(.multiplexer("herdr")))
        #expect(reading.check(agent: 22, facts: facts) == .unknown(.multiplexer("herdr")))
        #expect(reading.check(agent: 12, facts: facts) == .unknown(.multiplexer("herdr")))
    }

    @Test func aHerdrPaneWhoseShellIsGoneIsUnknown() {
        let facts = Self.herdrSetup()
        facts.outputs[Self.herdrCommand("pane", "list")] = Self.panes(("w1:p2", true))
        facts.table[21] = nil
        #expect(FrontPanes.read(Self.front("/dev/ttys000"), facts: facts) == .unknown(.multiplexer("herdr")))
    }

    @Test func tmuxsPaneIsTheOneItsClientOnTheFrontTtyShows() {
        let facts = Facts()
            .add(10, parent: 1, ["ghostty"], app: Self.ghostty)
            .add(12, parent: 10, tty: "/dev/ttys000", ["tmux", "attach"], executable: Self.tmux)
            .add(13, parent: 10, tty: "/dev/ttys001", ["tmux", "attach"], executable: Self.tmux)
            .add(22, parent: 1, tty: "/dev/ttys007", ["claude"])
            .add(32, parent: 1, tty: "/dev/ttys009", ["pi"])
        facts.outputs[[Self.tmux, "list-clients", "-F", "#{client_tty}\t#{pane_tty}"]] = "/dev/ttys001\t/dev/ttys007\n/dev/ttys000\t/dev/ttys009"
        let reading = FrontPanes.read(Self.front("/dev/ttys000"), facts: facts)
        #expect(reading == .pane(FrontPane(app: Self.ghostty, tty: "/dev/ttys009", multiplexers: ["tmux"])))
        #expect(reading.check(agent: 32, facts: facts) == .shown)
        #expect(reading.check(agent: 22, facts: facts) == .elsewhere)
    }

    @Test func tmuxIsAskedOnTheSocketItsClientWasStartedWith() {
        let facts = Facts()
            .add(10, parent: 1, ["ghostty"], app: Self.ghostty)
            .add(12, parent: 10, tty: "/dev/ttys000", ["tmux", "-L", "work", "attach"], executable: Self.tmux)
            .add(22, parent: 1, tty: "/dev/ttys007", ["claude"])
        facts.outputs[[Self.tmux, "-L", "work", "list-clients", "-F", "#{client_tty}\t#{pane_tty}"]] = "/dev/ttys000\t/dev/ttys007"
        #expect(FrontPanes.read(Self.front("/dev/ttys000"), facts: facts).check(agent: 22, facts: facts) == .shown)
        facts.add(12, parent: 10, tty: "/dev/ttys000", ["tmux", "-S", "/tmp/s", "attach"], executable: Self.tmux)
        facts.outputs[[Self.tmux, "-S", "/tmp/s", "list-clients", "-F", "#{client_tty}\t#{pane_tty}"]] = "/dev/ttys000\t/dev/ttys007"
        #expect(FrontPanes.read(Self.front("/dev/ttys000"), facts: facts).check(agent: 22, facts: facts) == .shown)
    }

    @Test func aTmuxClientThatIsNotListedIsUnknown() {
        let facts = Facts()
            .add(12, parent: 1, tty: "/dev/ttys000", ["tmux"], executable: Self.tmux)
        facts.outputs[[Self.tmux, "list-clients", "-F", "#{client_tty}\t#{pane_tty}"]] = "/dev/ttys001\t/dev/ttys007"
        #expect(FrontPanes.read(Self.front("/dev/ttys000"), facts: facts) == .unknown(.multiplexer("tmux")))
    }

    @Test func tmuxInsideAHerdrPaneIsFollowedToItsOwnPane() {
        let facts = Self.herdrSetup()
            .add(33, parent: 31, tty: "/dev/ttys009", ["tmux"], executable: Self.tmux)
            .add(42, parent: 1, tty: "/dev/ttys011", ["codex"])
        facts.outputs[Self.herdrCommand("pane", "list")] = Self.panes(("w2:p1", true))
        facts.outputs[[Self.tmux, "list-clients", "-F", "#{client_tty}\t#{pane_tty}"]] = "/dev/ttys009\t/dev/ttys011"
        let reading = FrontPanes.read(Self.front("/dev/ttys000"), facts: facts)
        #expect(reading == .pane(FrontPane(app: Self.ghostty, tty: "/dev/ttys011", multiplexers: ["herdr", "tmux"])))
        #expect(reading.check(agent: 42, facts: facts) == .shown)
        #expect(reading.check(agent: 32, facts: facts) == .elsewhere)
    }

    private static let zellij = "/opt/homebrew/bin/zellij"
    private static let zellijSocket = "/var/folders/T/zellij-501/contract_version_1/quiet-otter"
    private static let listClients = [zellij, "--session", "quiet-otter", "action", "list-clients"]
    private static let zellijDirectory = "/var/folders/T/zellij-501/contract_version_1"

    private static func zellijClients(_ panes: String...) -> String {
        (["CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND"] + panes.enumerated().map { "\($0.offset + 1)         \($0.element)     claude" })
            .joined(separator: "\n") + "\n"
    }

    private static func zellijSetup(clients: String? = zellijClients("terminal_1")) -> Facts {
        let facts = Facts()
            .add(10, parent: 1, ["ghostty"], app: ghostty)
            .add(11, parent: 10, tty: "/dev/ttys041", ["-zsh"])
            .add(80, parent: 11, tty: "/dev/ttys041", ["zellij"], executable: zellij)
            .add(84, parent: 1, [zellij, "--server", zellijSocket], executable: zellij)
            .add(85, parent: 84, tty: "/dev/ttys050", ["-zsh"])
            .add(90, parent: 85, tty: "/dev/ttys050", ["claude"], environment: ["ZELLIJ_PANE_ID": "1"])
            .add(86, parent: 84, tty: "/dev/ttys051", ["-zsh"])
            .add(91, parent: 86, tty: "/dev/ttys051", ["pi"], environment: ["ZELLIJ_PANE_ID": "2"])
            .add(92, parent: 86, tty: "/dev/ttys052", ["codex"])
            .add(184, parent: 1, [zellij, "--server", "/var/folders/T/zellij-501/contract_version_1/other"], executable: zellij)
            .add(190, parent: 184, tty: "/dev/ttys060", ["claude"], environment: ["ZELLIJ_PANE_ID": "1"])
        facts.outputs[["/usr/sbin/lsof", "-U", "-a", "-c", "zellij", "-F", "pdn"]] = """
            p80
            f5
            d0xclient
            n->0xaccepted
            f7
            d0xpairA
            n->0xpairB
            f8
            d0xpairB
            n->0xpairA
            p84
            f5
            d0xlisten
            n\(zellijSocket)
            f6
            d0xaccepted
            n\(zellijSocket)
            p184
            f5
            d0xotherlisten
            n/var/folders/T/zellij-501/contract_version_1/other
            """
        facts.outputs[listClients] = clients
        facts.owners[zellijDirectory] = ["other": 184, "quiet-otter": 84]
        return facts
    }

    @Test func zellijsFocusedPaneIsFoundThroughTheSessionTheClientIsConnectedTo() {
        let facts = Self.zellijSetup()
        let reading = FrontPanes.read(Self.front("/dev/ttys041"), facts: facts)
        #expect(reading == .pane(FrontPane(
            app: Self.ghostty, tty: "/dev/ttys041", multiplexers: ["Zellij"], view: FrontView(host: "Zellij", server: 84, pane: "terminal_1"))))
        #expect(reading.check(agent: 90, facts: facts) == .shown)
        #expect(reading.check(agent: 91, facts: facts) == .elsewhere)
    }

    @Test func theSamePaneInAnotherZellijSessionIsNotShown() {
        let facts = Self.zellijSetup()
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts).check(agent: 190, facts: facts) == .elsewhere)
    }

    @Test func anAgentInTheFrontZellijSessionThatReportedNoPaneIsUnknown() {
        let facts = Self.zellijSetup()
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts).check(agent: 92, facts: facts) == .unknown(.unreported("Zellij")))
    }

    @Test func zellijClientsShowingDifferentPanesCannotSayWhichIsInFront() {
        let facts = Self.zellijSetup(clients: Self.zellijClients("terminal_1", "terminal_2"))
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts) == .unknown(.severalViews("Zellij")))
        facts.outputs[Self.listClients] = Self.zellijClients("terminal_1", "terminal_1")
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts).check(agent: 90, facts: facts) == .shown)
    }

    @Test func aFocusedZellijPluginShowsNoAgent() {
        let facts = Self.zellijSetup(clients: Self.zellijClients("plugin_1"))
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts).check(agent: 90, facts: facts) == .elsewhere)
    }

    @Test func aZellijThatCannotBeReadIsUnknown() {
        let facts = Self.zellijSetup(clients: nil)
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts) == .unknown(.multiplexer("Zellij")))
        facts.outputs[Self.listClients] = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n"
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts) == .unknown(.multiplexer("Zellij")))
        facts.outputs[Self.listClients] = "something else entirely\n"
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts) == .unknown(.multiplexer("Zellij")))
        facts.outputs[["/usr/sbin/lsof", "-U", "-a", "-c", "zellij", "-F", "pdn"]] = "p80\nf5\nd0xclient\nn->0xnowhere\n"
        facts.outputs[Self.listClients] = Self.zellijClients("terminal_1")
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts) == .unknown(.multiplexer("Zellij")))
    }

    @Test func aRenamedZellijSessionIsFoundByTheServerListeningOnItsSocket() {
        let facts = Self.zellijSetup()
        facts.owners[Self.zellijDirectory] = ["renamed": 84, "quiet-otter": 184]
        facts.outputs[[Self.zellij, "--session", "renamed", "action", "list-clients"]] = Self.zellijClients("terminal_2")
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts).check(agent: 91, facts: facts) == .shown)
    }

    @Test func aZellijSessionNameWithSpacesIsKeptWhole() {
        let facts = Self.zellijSetup()
        facts.owners[Self.zellijDirectory] = ["work project": 84]
        facts.outputs[[Self.zellij, "--session", "work project", "action", "list-clients"]] = Self.zellijClients("terminal_1")
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts).check(agent: 90, facts: facts) == .shown)
    }

    @Test func aZellijServerWithoutExactlyOneSocketIsUnknown() {
        let facts = Self.zellijSetup()
        facts.owners[Self.zellijDirectory] = ["other": 184]
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts) == .unknown(.multiplexer("Zellij")))
        facts.owners[Self.zellijDirectory] = ["quiet-otter": 84, "copy": 84]
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts) == .unknown(.multiplexer("Zellij")))
        facts.owners[Self.zellijDirectory] = nil
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts) == .unknown(.multiplexer("Zellij")))
    }

    @Test func anAgentUnderAnotherMultiplexerIsUnknownWhenProcessesCannotBeListed() {
        let facts = Self.zellijSetup()
            .add(70, parent: 1, ["tmux", "new-session"], executable: Self.tmux)
            .add(71, parent: 70, tty: "/dev/ttys070", ["claude"])
        facts.outputs[Self.listClients] = Self.zellijClients("terminal_3")
        let reading = FrontPanes.read(Self.front("/dev/ttys041"), facts: facts)
        #expect(reading.check(agent: 71, facts: facts) == .elsewhere)
        facts.namesUnreadable = true
        #expect(reading.check(agent: 71, facts: facts) == .unknown(.processesUnreadable))
    }

    @Test func anAgentInTmuxInsideTheFrontZellijIsUnknownNotElsewhere() {
        let facts = Self.zellijSetup()
            .add(87, parent: 84, tty: "/dev/ttys053", ["-zsh"])
            .add(88, parent: 87, tty: "/dev/ttys053", ["tmux"], executable: Self.tmux)
            .add(70, parent: 1, ["tmux", "new-session"], executable: Self.tmux)
            .add(71, parent: 70, tty: "/dev/ttys070", ["claude"])
        facts.outputs[Self.listClients] = Self.zellijClients("terminal_3")
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts).check(agent: 71, facts: facts) == .unknown(.nested("Zellij")))
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts).check(agent: 190, facts: facts) == .elsewhere)
    }

    @Test func zellijInsideTmuxIsFollowedToItsFocusedPane() {
        let facts = Self.zellijSetup()
            .add(12, parent: 10, tty: "/dev/ttys000", ["tmux", "attach"], executable: Self.tmux)
        facts.outputs[[Self.tmux, "list-clients", "-F", "#{client_tty}\t#{pane_tty}"]] = "/dev/ttys000\t/dev/ttys041"
        let reading = FrontPanes.read(Self.front("/dev/ttys000"), facts: facts)
        #expect(reading == .pane(FrontPane(
            app: Self.ghostty, tty: "/dev/ttys041", multiplexers: ["tmux", "Zellij"], view: FrontView(host: "Zellij", server: 84, pane: "terminal_1"))))
        #expect(reading.check(agent: 90, facts: facts) == .shown)
    }

    @Test func aSuspendedZellijAgentIsNotShown() {
        let facts = Self.zellijSetup()
            .add(90, parent: 85, tty: "/dev/ttys050", ["claude"], environment: ["ZELLIJ_PANE_ID": "1"], foreground: false)
        #expect(FrontPanes.read(Self.front("/dev/ttys041"), facts: facts).check(agent: 90, facts: facts) == .elsewhere)
    }

    @Test func anAgentReportsTheEnvironmentItsOwnProcessCannotBeReadFor() {
        let facts = Self.zellijSetup()
        let reported = facts.reporting(["ZELLIJ_PANE_ID": "1", "HOME": "/Users/me"], for: 92)
        #expect(reported.process(92)?.environment == ["ZELLIJ_PANE_ID": "1"])
        #expect(reported.process(91)?.environment == ["ZELLIJ_PANE_ID": "2"])
        #expect(facts.reporting(["ZELLIJ_PANE_ID": "9"], for: 91).process(91)?.environment == ["ZELLIJ_PANE_ID": "2"])
        #expect(reported.processes(onTTY: "/dev/ttys052")?.map(\.environment) == [["ZELLIJ_PANE_ID": "1"]])
    }

    @Test func aSuspendedMultiplexerClientShowsTheShellInstead() {
        let facts = Facts()
            .add(10, parent: 1, ["ghostty"], app: Self.ghostty)
            .add(11, parent: 10, tty: "/dev/ttys000", ["-zsh"])
            .add(12, parent: 11, tty: "/dev/ttys000", ["tmux", "attach"], executable: Self.tmux, foreground: false)
            .add(22, parent: 1, tty: "/dev/ttys007", ["claude"])
        facts.outputs[[Self.tmux, "list-clients", "-F", "#{client_tty}\t#{pane_tty}"]] = "/dev/ttys000\t/dev/ttys007"
        let reading = FrontPanes.read(Self.front("/dev/ttys000"), facts: facts)
        #expect(reading == .pane(FrontPane(app: Self.ghostty, tty: "/dev/ttys000", multiplexers: [])))
        #expect(reading.check(agent: 22, facts: facts) == .elsewhere)
    }

    @Test func aSuspendedAgentInTheFrontTabIsNotShown() {
        let facts = Facts()
            .add(20, parent: 1, tty: "/dev/ttys004", ["-zsh"])
            .add(30, parent: 20, tty: "/dev/ttys004", ["claude"], foreground: false)
            .add(40, parent: 1, tty: "/dev/ttys060", ["pi"])
            .add(41, parent: 1, tty: "/dev/ttys058", ["python3", "ptywrap.py"], foreground: false)
            .add(42, parent: 41, tty: "/dev/ttys059", ["claude"])
        #expect(FrontPanes.read(Self.front("/dev/ttys004"), facts: facts).check(agent: 30, facts: facts) == .elsewhere)
        #expect(FrontPanes.read(Self.front("/dev/ttys058"), facts: facts).check(agent: 42, facts: facts) == .elsewhere)
    }

    @Test func processesThatCannotBeListedAreUnknownNotAPlainTab() {
        let facts = Self.herdrSetup()
        facts.unreadableTTYs = ["/dev/ttys000"]
        #expect(FrontPanes.read(Self.front("/dev/ttys000"), facts: facts) == .unknown(.processesUnreadable))
        facts.unreadableTTYs = ["/dev/ttys007"]
        facts.outputs[Self.herdrCommand("pane", "list")] = Self.panes(("w1:p2", true))
        #expect(FrontPanes.read(Self.front("/dev/ttys000"), facts: facts) == .unknown(.processesUnreadable))
    }

    @Test func twoMultiplexerClientsOnOneTtyAreUnknown() {
        let facts = Facts()
            .add(12, parent: 1, tty: "/dev/ttys000", ["tmux"], executable: Self.tmux)
            .add(13, parent: 1, tty: "/dev/ttys000", ["herdr"], executable: Self.herdr)
        #expect(FrontPanes.read(Self.front("/dev/ttys000"), facts: facts) == .unknown(.ambiguous))
    }

    @Test func aFrontTerminalWithoutATtyIsUnknown() {
        #expect(FrontPanes.read(Self.front(nil), facts: Facts()) == .unknown(.noTerminal))
    }

    @Test func aGoneAgentIsNotShown() {
        let facts = Facts().add(30, parent: 1, tty: "/dev/ttys004", ["claude"])
        let reading = FrontPanes.read(Self.front("/dev/ttys004"), facts: facts)
        #expect(reading.check(agent: 99, facts: facts) == .elsewhere)
    }
}
