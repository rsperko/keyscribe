import Foundation
import Testing
@testable import KeyScribeKit

struct AgentProcessesTests {
    let home = "/Users/a"

    private func process(
        _ pid: Int, parent: Int = 1, name: String = "node", arguments: [String], environment: [String: String] = [:],
        tty: String? = "/dev/ttys001", directory: String? = "/Users/a/src/atlas", startedAt: Int? = 100, readable: Bool = true
    ) -> TerminalProcess {
        TerminalProcess(
            pid: pid, parent: parent, tty: tty, arguments: arguments, environment: environment, executable: "/usr/local/bin/\(name)",
            app: nil, directory: directory, startedAt: startedAt, argumentsReadable: readable)
    }

    @Test func aPiProcessUsesItsOwnSetupFolderOrPisDefault() {
        let found = AgentProcesses.classify([
            process(10, arguments: ["pi"], environment: ["PI_CODING_AGENT_DIR": "/Users/a/pi-work"]),
            process(11, arguments: ["pi"], directory: "/Users/a/src/other"),
            process(12, arguments: ["pi"], environment: ["PI_CODING_AGENT_DIR": "~/pi-home"]),
        ], rule: .pi, home: home)
        #expect(found.candidates.map(\.setup) == ["/Users/a/pi-work", "/Users/a/.pi/agent", "/Users/a/pi-home"])
        #expect(found.candidates.map(\.cwd) == ["/Users/a/src/atlas", "/Users/a/src/other", "/Users/a/src/atlas"])
        #expect(found.candidates.map(\.startedAt) == [100, 100, 100])
        #expect(found.unreadable.isEmpty)
    }

    @Test func aPiStartedByAnotherPiIsASubagentNotAConversation() {
        let found = AgentProcesses.classify([
            process(10, arguments: ["pi"]),
            process(20, parent: 15, arguments: ["pi"], tty: nil),
            process(15, parent: 10, name: "zsh", arguments: ["/bin/zsh", "-c", "pi -p"]),
            process(21, parent: 10, arguments: ["pi"]),
        ], rule: .pi, home: home, parent: { [15: 10][$0] })
        #expect(found.candidates.map(\.pid) == [10])
    }

    @Test func aBackgroundPiWithoutATerminalIsNotAConversation() {
        let found = AgentProcesses.classify([process(10, arguments: ["pi"], tty: nil)], rule: .pi, home: home)
        #expect(found.candidates.isEmpty)
    }

    @Test func otherNodeProgramsAndUnreadableProcessesAreKeptApart() {
        let found = AgentProcesses.classify([
            process(10, arguments: ["node", "server.js"]),
            process(11, arguments: [], readable: false),
            process(12, name: "pi", arguments: ["/opt/bin/pi", "--continue"]),
            process(13, name: "pi", arguments: [], readable: false),
        ], rule: .pi, home: home)
        #expect(found.candidates.map(\.pid) == [12])
        #expect(found.unreadable == [13])
    }

    @Test func anUnreadableProcessCountsOnlyWhenItsNameIsTheAgentsOwn() {
        let found = AgentProcesses.classify([
            process(20, name: "node", arguments: [], readable: false),
            process(21, name: "2.1.319", arguments: [], readable: false),
            process(22, name: "claude", arguments: [], readable: false),
        ], rule: .claude, home: home)
        #expect(found.unreadable == [21, 22])
    }

    @Test func aRelativeSetupFolderIsResolvedFromTheProcesssOwnFolder() {
        let found = AgentProcesses.classify([
            process(30, name: "2.1.319", arguments: ["claude"], environment: ["CLAUDE_CONFIG_DIR": ".claude-work"]),
            process(31, name: "2.1.319", arguments: ["claude"], environment: ["CLAUDE_CONFIG_DIR": "../shared/.claude"]),
        ], rule: .claude, home: home)
        #expect(found.candidates.map(\.setup) == ["/Users/a/src/atlas/.claude-work", "/Users/a/src/shared/.claude"])
    }

    @Test func claudeIsFoundByItsCommandHoweverItWasInstalled() {
        let found = AgentProcesses.classify([
            process(30, name: "2.1.319", arguments: ["claude"], environment: ["CLAUDE_CONFIG_DIR": "/Users/a/.claude-work"]),
            process(31, name: "node", arguments: ["node", "/Users/a/.npm/bin/claude", "--resume"]),
            process(32, name: "2.1.319", arguments: ["/Users/a/.local/bin/claude"]),
            process(33, name: "node", arguments: ["node", "/x/claude-helper.js"]),
        ], rule: .claude, home: home)
        #expect(found.candidates.map(\.pid) == [30, 31, 32])
        #expect(found.candidates.map(\.setup) == ["/Users/a/.claude-work", "/Users/a/.claude", "/Users/a/.claude"])
        #expect(found.setups == ["/Users/a/.claude-work", "/Users/a/.claude"])
    }

    @Test func onlyProcessNamesAnAgentCouldRunUnderAreRead() {
        #expect(AgentProcesses.Rule.pi.mayBe(name: "node"))
        #expect(AgentProcesses.Rule.pi.mayBe(name: "pi"))
        #expect(!AgentProcesses.Rule.pi.mayBe(name: "zsh"))
        #expect(AgentProcesses.Rule.claude.mayBe(name: "2.1.319"))
        #expect(AgentProcesses.Rule.claude.mayBe(name: "claude"))
        #expect(!AgentProcesses.Rule.claude.mayBe(name: "Safari"))
    }
}
