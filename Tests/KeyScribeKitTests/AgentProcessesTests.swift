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

    private let installed: [String: AgentProcesses.Resolved] = [
        "/Users/a/.npm/bin/claude": .init(path: "/Users/a/.npm/lib/node_modules/@anthropic-ai/claude-code/cli.js", executable: true),
        "/Users/a/bin/cc": .init(path: "/Users/a/.npm/lib/node_modules/@anthropic-ai/claude-code/cli.js", executable: true),
        "/nix/store/x-claude-code/bin/claude": .init(path: "/nix/store/x-claude-code/bin/claude", executable: true),
        "/nix/store/x-claude-code/bin/.claude-wrapped": .init(path: "/nix/store/x-claude-code/bin/.claude-wrapped", executable: true),
        "/Users/a/.nvm/versions/node/v24/bin/pi": .init(
            path: "/Users/a/.nvm/versions/node/v24/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js", executable: true),
        "/Users/a/.bun/install/global/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js": .init(
            path: "/Users/a/.bun/install/global/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js", executable: false),
        "/Users/a/src/atlas/pi": .init(path: "/Users/a/src/atlas/pi", executable: false),
        "/Users/a/src/atlas/bin/pi": .init(path: "/Users/a/src/atlas/bin/pi", executable: true),
        "/Users/a/.local/bin/pi": .init(path: "/Users/a/.local/bin/pi", executable: true),
        "/Users/a/bin/pi": .init(path: "/Users/a/bin/pi", executable: true),
    ]

    private var resolve: (String) -> AgentProcesses.Resolved? { { [installed] in installed[$0] } }

    @Test func claudeIsFoundByItsCommandHoweverItWasInstalled() {
        let found = AgentProcesses.classify([
            process(30, name: "2.1.319", arguments: ["claude"], environment: ["CLAUDE_CONFIG_DIR": "/Users/a/.claude-work"]),
            process(31, name: "node", arguments: ["node", "/Users/a/.npm/bin/claude", "--resume"]),
            process(32, name: "2.1.319", arguments: ["/Users/a/.local/bin/claude"]),
            process(33, name: "node", arguments: ["node", "/x/claude-helper.js"]),
        ], rule: .claude, home: home, resolve: resolve)
        #expect(found.candidates.map(\.pid) == [30, 31, 32])
        #expect(found.candidates.map(\.setup) == ["/Users/a/.claude-work", "/Users/a/.claude", "/Users/a/.claude"])
        #expect(found.setups == ["/Users/a/.claude-work", "/Users/a/.claude"])
    }

    @Test func aWrappedBinaryIsFoundAndReportsItsWrapper() {
        let found = AgentProcesses.classify([
            process(40, name: ".claude-wrapped", arguments: ["/nix/store/x-claude-code/bin/.claude-wrapped", "--resume"]),
            process(41, name: ".claude-wrapped", arguments: ["/nix/store/x-claude-code/bin/claude"]),
        ], rule: .claude, home: home, resolve: resolve)
        #expect(found.candidates.map(\.pid) == [40, 41])
        #expect(found.candidates.map(\.tool) == ["/nix/store/x-claude-code/bin/claude", "/nix/store/x-claude-code/bin/claude"])
    }

    @Test func anyRuntimeRunningTheAgentsScriptIsTheAgent() {
        let script = "/Users/a/.bun/install/global/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
        var bun = process(50, name: "bun", arguments: ["bun", script])
        bun.executable = "/opt/homebrew/Cellar/bun/1.4.2/bin/bun"
        let found = AgentProcesses.classify([
            bun,
            process(51, name: "node", arguments: ["node", "--max-old-space-size=4096", "/Users/a/.nvm/versions/node/v24/bin/pi", "--continue"]),
            process(52, name: "deno", arguments: ["deno", "run", "-A", "/Users/a/src/atlas/bin/pi"]),
            process(53, name: "node", arguments: ["node", "./bin/pi"]),
        ], rule: .pi, home: home, resolve: resolve)
        #expect(found.candidates.map(\.pid) == [50, 51, 52, 53])
        #expect(found.candidates.map(\.tool) == [
            script, "/Users/a/.nvm/versions/node/v24/bin/pi", "/Users/a/src/atlas/bin/pi", "/Users/a/src/atlas/bin/pi",
        ])
        #expect(found.candidates.first?.runtime == "/opt/homebrew/Cellar/bun/1.4.2/bin/bun")
    }

    @Test func aScriptLinkedUnderAnotherNameIsFoundByWhereItLeads() {
        let found = AgentProcesses.classify([process(60, arguments: ["node", "/Users/a/bin/cc"])], rule: .claude, home: home, resolve: resolve)
        #expect(found.candidates.map(\.pid) == [60])
    }

    @Test func aProgramThatOnlyOpensTheAgentsCommandIsNotTheAgent() {
        let found = AgentProcesses.classify([
            process(70, name: "vim", arguments: ["vim", "bin/pi"]),
            process(71, name: "less", arguments: ["less", "/Users/a/.local/bin/pi"]),
            process(72, name: "Code Helper", arguments: ["/Applications/Code.app/Contents/MacOS/Electron", "--wait", "/Users/a/.local/bin/pi"]),
            process(73, name: "cat", arguments: ["cat", "claude.md"]),
            process(74, name: "git", arguments: ["git", "log", "/Users/a/.local/bin/pi"]),
        ], rule: .pi, home: home, resolve: resolve)
        #expect(found.candidates.isEmpty)
    }

    @Test func onlyTheScriptSlotOfARuntimeIsRead() {
        let found = AgentProcesses.classify([
            process(75, name: "node", arguments: ["node", "/x/server.js", "/Users/a/.local/bin/pi"]),
            process(76, name: "bun", arguments: ["bun", "run", "/Users/a/.local/bin/pi"]),
            process(77, name: ".node-wrapped", arguments: ["/nix/store/n/bin/.node-wrapped", "/Users/a/.local/bin/pi"]),
        ], rule: .pi, home: home, resolve: resolve)
        #expect(found.candidates.map(\.pid) == [76, 77])
    }

    @Test func aWrapperScriptThatStaysRunningLeavesTheSessionToItsChild() {
        var child = process(
            81, parent: 80, name: "node",
            arguments: ["node", "/Users/a/.nvm/versions/node/v24/bin/pi", "--continue"],
            environment: ["PI_CODING_AGENT_DIR": "/Users/a/pi-work"])
        child.executable = "/Users/a/.nvm/versions/node/v24/bin/node"
        let found = AgentProcesses.classify([
            process(80, name: "bash", arguments: ["/bin/bash", "/Users/a/.local/bin/pi"]),
            child,
        ], rule: .pi, home: home, resolve: resolve)
        #expect(found.candidates.map(\.pid) == [81])
        #expect(found.candidates.map(\.setup) == ["/Users/a/pi-work"])
    }

    @Test func aChainOfWrappersLeavesTheSessionToTheAgentAtTheEnd() {
        for order in [[80, 83, 81], [81, 83, 80], [83, 80, 81]] {
            var child = process(81, parent: 83, name: "node", arguments: ["node", "/Users/a/.nvm/versions/node/v24/bin/pi"])
            child.executable = "/Users/a/.nvm/versions/node/v24/bin/node"
            let all = [
                80: process(80, name: "bash", arguments: ["/bin/bash", "/Users/a/.local/bin/pi"]),
                83: process(83, parent: 80, name: "sh", arguments: ["/bin/sh", "/Users/a/bin/pi"]),
                81: child,
            ]
            let found = AgentProcesses.classify(order.compactMap { all[$0] }, rule: .pi, home: home, resolve: resolve)
            #expect(found.candidates.map(\.pid) == [81], "order \(order)")
        }
    }

    @Test func aWrapperThatStartsTheAgentThroughAnotherProgramLeavesTheSessionToTheAgent() {
        var child = process(86, parent: 85, name: "node", arguments: ["node", "/Users/a/.nvm/versions/node/v24/bin/pi"])
        child.executable = "/Users/a/.nvm/versions/node/v24/bin/node"
        let found = AgentProcesses.classify([
            process(84, name: "bash", arguments: ["/bin/bash", "/Users/a/.local/bin/pi"]),
            process(85, parent: 84, name: "caffeinate", arguments: ["caffeinate", "-i", "pi"]),
            child,
        ], rule: .pi, home: home, resolve: resolve)
        #expect(found.candidates.map(\.pid) == [86])
    }

    @Test func aWrapperScriptThatHasNotStartedTheAgentYetIsStillListed() {
        let found = AgentProcesses.classify([process(82, name: "bash", arguments: ["/bin/bash", "/Users/a/.local/bin/pi"])], rule: .pi, home: home, resolve: resolve)
        #expect(found.candidates.map(\.pid) == [82])
    }

    @Test func anAgentStartedByAnAgentThroughAWrapperIsStillNotASession() {
        let found = AgentProcesses.classify([
            process(90, arguments: ["pi"]),
            process(91, parent: 90, name: "bash", arguments: ["/bin/bash", "/Users/a/.local/bin/pi"]),
            process(92, parent: 91, arguments: ["node", "/Users/a/.nvm/versions/node/v24/bin/pi"]),
        ], rule: .pi, home: home, resolve: resolve)
        #expect(found.candidates.map(\.pid) == [90])
    }

    @Test func theNativeClaudeReportsTheBinaryItRuns() {
        var native = process(80, name: "2.1.326", arguments: ["claude", "--resume"])
        native.executable = "/Users/a/.local/share/claude/versions/2.1.326"
        let found = AgentProcesses.classify([native], rule: .claude, home: home, resolve: resolve)
        #expect(found.candidates.map(\.tool) == ["/Users/a/.local/share/claude/versions/2.1.326"])
    }

    @Test func aRenamedNativeBinaryIsFoundByItsInstallFolder() {
        var renamed = process(81, name: "2.1.326", arguments: ["cc"])
        renamed.executable = "/Users/a/.local/share/claude/versions/2.1.326"
        let found = AgentProcesses.classify([renamed], rule: .claude, home: home, resolve: resolve)
        #expect(found.candidates.map(\.pid) == [81])
    }

    @Test func anUnreadableWrappedProcessMakesTheScanPartial() {
        let found = AgentProcesses.classify([
            process(90, name: ".pi-wrapped", arguments: [], readable: false),
            process(91, name: "zsh", arguments: [], readable: false),
        ], rule: .pi, home: home, resolve: resolve)
        #expect(found.unreadable == [90])
        #expect(found.isPartial)
    }

    @Test func mentionsCatchNearMissesForDiagnosis() {
        #expect(AgentProcesses.Rule.pi.mentions(process(1, name: "pi-full", arguments: ["/bin/sh", "/Users/a/.pi/agent/bin/pi-full"])))
        #expect(AgentProcesses.Rule.claude.mentions(process(2, name: "Claude Helper", arguments: ["/Applications/Claude.app/x"])))
        #expect(!AgentProcesses.Rule.pi.mentions(process(3, name: "zsh", arguments: ["-zsh"])))
    }

    @Test func pathsBehindAPrivacyPromptOrOnAnotherVolumeAreNeverLookedAt() {
        for path in [
            "/Users/a/Documents/tools/pi", "/Users/a/Desktop/pi", "/Users/a/Downloads/pi", "/Users/a/Library/Mobile Documents/x/pi",
            "/Users/a/Library/CloudStorage/Drive/pi", "/Volumes/USB/pi", "/Network/Servers/x/pi", "/net/host/pi", "/Users/a/Pictures/pi",
        ] {
            #expect(!AgentProcesses.mayLookAt(path, home: "/Users/a"), "\(path)")
        }
        for path in ["/Users/a/.local/bin/pi", "/opt/homebrew/bin/claude", "/nix/store/x/bin/claude", "/Users/a/src/atlas/bin/pi"] {
            #expect(AgentProcesses.mayLookAt(path, home: "/Users/a"), "\(path)")
        }
    }
}
