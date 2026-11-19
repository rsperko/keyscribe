import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct TerminalTitleReaderTests {
    final class Facts: TerminalFacts, @unchecked Sendable {
        var table: [Int: TerminalProcess] = [:]
        var outputs: [[String]: String] = [:]
        private let lock = NSLock()
        private var commands: [[String]] = []

        var ran: [[String]] { lock.withLock { commands } }

        @discardableResult
        func add(
            _ pid: Int, parent: Int?, tty: String? = nil, _ arguments: [String], environment: [String: String] = [:], app: String? = nil
        ) -> Facts {
            table[pid] = TerminalProcess(
                pid: pid, parent: parent, tty: tty, arguments: arguments, environment: environment, executable: arguments[0], app: app)
            return self
        }

        func process(_ pid: Int) -> TerminalProcess? { table[pid] }
        func processes(named name: String) -> [TerminalProcess]? { table.values.filter { $0.name == name } }
        func processes(onTTY tty: String) -> [TerminalProcess]? { table.values.filter { $0.tty == tty } }
        func children(of pid: Int) -> [TerminalProcess]? { table.values.filter { $0.parent == pid } }
        func socketOwners(in directory: String) -> [String: Int]? { nil }
        func run(_ argv: [String]) -> (status: Int32, output: String) {
            lock.withLock { commands.append(argv) }
            return outputs[argv].map { (0, $0) } ?? (1, "")
        }
    }

    final class Scripts: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        let answer: TerminalRead

        init(_ answer: TerminalRead) { self.answer = answer }

        var asked: [String] { lock.withLock { calls } }

        func read(_ app: String, _ pid: Int, _ body: String) -> TerminalRead {
            lock.withLock { calls.append("\(app) \(pid)") }
            return answer
        }
    }

    private static let ghostty = "com.mitchellh.ghostty"
    private static let tmux = "/opt/homebrew/bin/tmux"
    private static let socket = "/private/tmp/tmux-501/default"
    private static let titleCommand = [tmux, "-S", socket, "list-panes", "-a", "-F", "#{pane_tty}\t#{pane_title}"]
    private static let first = "codex 019a3c5e-7d21-7f40-9b8e-41c2d7a0e6f1"
    private static let second = "codex 019a3c60-0b12-7c33-a1d4-6e2f9b8c7d05"

    private func facts() -> Facts {
        let tmuxed = ["TMUX": "\(Self.socket),60,0"]
        let facts = Facts()
            .add(10, parent: 1, ["ghostty"], app: Self.ghostty)
            .add(20, parent: 10, tty: "/dev/ttys004", ["/usr/bin/login"])
            .add(30, parent: 20, tty: "/dev/ttys004", ["codex"])
            .add(21, parent: 10, tty: "/dev/ttys005", ["/usr/bin/login"])
            .add(31, parent: 21, tty: "/dev/ttys005", ["codex"])
            .add(55, parent: 10, tty: "/dev/ttys003", [Self.tmux, "attach"])
            .add(60, parent: 1, [Self.tmux, "new", "-s", "work"])
            .add(70, parent: 60, tty: "/dev/ttys012", ["codex"], environment: tmuxed)
            .add(71, parent: 60, tty: "/dev/ttys013", ["codex"], environment: tmuxed)
        facts.outputs[Self.titleCommand] = "/dev/ttys012\t\(Self.first)\n/dev/ttys013\t\(Self.second)\n"
        return facts
    }

    private let ghosttyAnswer = "/dev/ttys004\t\tcodex 019a3c61-terminal-a\n/dev/ttys005\t\tzsh\n/dev/ttys003\t\ttmux work\n"

    private func reader(_ facts: Facts, _ scripts: Scripts) -> TerminalTitleReader {
        TerminalTitleReader(surfaces: .builtIn, facts: { facts }, script: { scripts.read($0, $1, $2) })
    }

    @Test func eachSurfaceIsReadOnceAndAPaneInsideAMultiplexerTakesThePaneTitleNotTheTabAroundIt() async {
        let facts = facts()
        let scripts = Scripts(.value(ghosttyAnswer))
        let titles = await reader(facts, scripts).titles(of: [30, 31, 70, 71, 70])
        #expect(titles == [30: "codex 019a3c61-terminal-a", 31: "zsh", 70: Self.first, 71: Self.second])
        #expect(facts.ran == [Self.titleCommand])
        #expect(scripts.asked == ["\(Self.ghostty) 10"])
    }

    @Test func aSurfaceThatFailsTimesOutOrMayNotBeAskedGivesNoTitle() async {
        for answer in [TerminalRead.failed, .notAllowed] {
            let facts = facts()
            facts.outputs[Self.titleCommand] = nil
            #expect(await reader(facts, Scripts(answer)).titles(of: [30, 70]).isEmpty)
        }
        #expect(await reader(facts(), Scripts(.value(ghosttyAnswer))).titles(of: [999]).isEmpty)
    }

    @Test func readingTitlesLeavesWhatThePlaceReadFindsForTheSameConversationsUnchanged() async {
        let facts = facts()
        let scripts = Scripts(.value(ghosttyAnswer))
        let places = TerminalPlaceReader(surfaces: .builtIn, facts: { facts }, script: { _, _, _ in .failed })
        let queries = [30, 70].map { AgentPlaceQuery(id: "a:\($0)", agent: "a", native: "\($0)", pid: $0) }
        let before = await places.read(queries)
        _ = await reader(facts, scripts).titles(of: [30, 70])
        #expect(await places.read(queries) == before)
    }
}
