import Foundation

public struct AgentCandidate: Equatable, Sendable {
    public var agent: String
    public var pid: Int
    public var startedAt: Int?
    public var cwd: String
    public var setup: String
    public var tty: String?

    public init(agent: String, pid: Int, startedAt: Int?, cwd: String, setup: String, tty: String? = nil) {
        self.agent = agent
        self.pid = pid
        self.startedAt = startedAt
        self.cwd = cwd
        self.setup = setup
        self.tty = tty
    }

    public var rowId: String { "process:\(pid):\(startedAt ?? 0)" }

    public func label(agentName: String) -> String {
        "\(agentName) in \(URL(fileURLWithPath: cwd).lastPathComponent)"
    }
}

public enum AgentProcesses {
    public struct Rule: Sendable {
        public var agent: String
        public var names: Set<String>
        public var anyVersionName: Bool
        public var command: String
        public var setupVariable: String
        public var defaultSetup: String
        public var needsTerminal: Bool

        public init(
            agent: String, names: Set<String>, anyVersionName: Bool, command: String, setupVariable: String, defaultSetup: String,
            needsTerminal: Bool
        ) {
            self.agent = agent
            self.names = names
            self.anyVersionName = anyVersionName
            self.command = command
            self.setupVariable = setupVariable
            self.defaultSetup = defaultSetup
            self.needsTerminal = needsTerminal
        }

        public func mayBe(name: String) -> Bool {
            names.contains(name) || (anyVersionName && Self.isVersion(name))
        }

        func isAgent(_ process: TerminalProcess) -> Bool {
            let commands = process.arguments.prefix(2).map { ($0 as NSString).lastPathComponent }
            if commands.first == command { return true }
            return commands.first == "node" && commands.count > 1 && commands[1] == command
        }

        func setup(_ process: TerminalProcess, home: String) -> String {
            let raw = process.environment[setupVariable].flatMap { $0.isEmpty ? nil : $0 } ?? defaultSetup
            return FolderPath.resolve(raw, home: home, relativeTo: process.directory ?? "/")
        }

        func isOwnName(_ name: String) -> Bool {
            name == command || (anyVersionName && Self.isVersion(name))
        }

        static func isVersion(_ name: String) -> Bool {
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        }
    }

    public struct Found: Equatable, Sendable {
        public var candidates: [AgentCandidate]
        public var unreadable: [Int]
        public var stale: Bool

        public init(candidates: [AgentCandidate] = [], unreadable: [Int] = [], stale: Bool = false) {
            self.candidates = candidates
            self.unreadable = unreadable
            self.stale = stale
        }

        public var isPartial: Bool { stale || !unreadable.isEmpty }

        public var setups: [String] {
            var seen: Set<String> = []
            return candidates.map(\.setup).filter { seen.insert($0).inserted }
        }
    }

    public static func classify(
        _ processes: [TerminalProcess], rule: Rule, home: String, parent: (Int) -> Int? = { _ in nil }
    ) -> Found {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let agents = Set(processes.filter { $0.argumentsReadable && rule.isAgent($0) }.map(\.pid))
        func startedByAgent(_ pid: Int) -> Bool {
            var next = byPid[pid]?.parent ?? parent(pid)
            var hops = 0
            while let at = next, at > 1, hops < 64 {
                if agents.contains(at) { return true }
                next = byPid[at]?.parent ?? parent(at)
                hops += 1
            }
            return false
        }
        var candidates: [AgentCandidate] = []
        var unreadable: [Int] = []
        for process in processes {
            guard process.argumentsReadable else {
                if rule.isOwnName(process.name) { unreadable.append(process.pid) }
                continue
            }
            guard agents.contains(process.pid), !rule.needsTerminal || process.tty != nil, !startedByAgent(process.pid) else { continue }
            candidates.append(AgentCandidate(
                agent: rule.agent, pid: process.pid, startedAt: process.startedAt, cwd: process.directory ?? "",
                setup: rule.setup(process, home: home), tty: process.tty))
        }
        return Found(candidates: candidates, unreadable: unreadable)
    }
}
