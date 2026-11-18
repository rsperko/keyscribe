import Foundation

public struct AgentCandidate: Equatable, Sendable {
    public var agent: String
    public var pid: Int
    public var startedAt: Int?
    public var cwd: String
    public var setup: String?
    public var tty: String?
    public var tool: String?
    public var runtime: String?

    public init(
        agent: String, pid: Int, startedAt: Int?, cwd: String, setup: String?, tty: String? = nil, tool: String? = nil, runtime: String? = nil
    ) {
        self.tool = tool
        self.runtime = runtime
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
    public struct Resolved: Equatable, Sendable {
        public var path: String
        public var executable: Bool

        public init(path: String, executable: Bool) {
            self.path = path
            self.executable = executable
        }
    }

    public struct Launch: Equatable, Sendable {
        public var tool: String
        public var runtime: String?
        public var throughShell = false
    }

    public struct Rule: Sendable {
        public var agent: String
        public var command: String
        public var packages: [String]
        public var anyVersionName: Bool
        public var setupVariable: String
        public var defaultSetup: String
        public var needsTerminal: Bool
        public var profileFlags: [String]
        public var profileVariables: [String]

        static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
        static let runtimes: [String: Set<String>] = [
            "node": [], "nodejs": [], "bun": ["run"], "deno": ["run"], "tsx": [], "ts-node": [],
        ].merging(shells.map { ($0, []) }) { own, _ in own }

        public init(
            agent: String, command: String, packages: [String], anyVersionName: Bool, setupVariable: String, defaultSetup: String,
            needsTerminal: Bool, profileFlags: [String] = [], profileVariables: [String] = []
        ) {
            self.agent = agent
            self.command = command
            self.packages = packages
            self.anyVersionName = anyVersionName
            self.setupVariable = setupVariable
            self.defaultSetup = defaultSetup
            self.needsTerminal = needsTerminal
            self.profileFlags = profileFlags
            self.profileVariables = profileVariables
        }

        public static func unwrapped(_ name: String) -> String {
            var plain = name
            while plain.hasPrefix(".") { plain.removeFirst() }
            while plain.hasSuffix("-wrapped") { plain.removeLast("-wrapped".count) }
            return plain
        }

        func names(_ path: String) -> Bool {
            Self.unwrapped((path as NSString).lastPathComponent) == command
        }

        func inPackage(_ path: String) -> Bool {
            packages.contains { path.contains($0) }
        }

        public func launch(of process: TerminalProcess, resolve: (String) -> Resolved?) -> Launch? {
            guard let first = process.arguments.first else { return nil }
            let executable = process.executable
            func isExecutable(_ path: String) -> Bool { resolve(path)?.executable ?? false }
            if names(first) || inPackage(first) || (!executable.isEmpty && (names(executable) || inPackage(executable))) {
                let own = first.hasPrefix("/") ? first : executable
                return Launch(tool: ToolSearch.launcher(for: own.isEmpty ? first : own, isExecutable: isExecutable))
            }
            guard let (script, runtime) = Self.script(of: process) else { return nil }
            let full = script.hasPrefix("/") ? script : process.directory.map { FolderPath.resolve(script, home: "/", relativeTo: $0) }
            guard let full, let resolved = resolve(full) else { return nil }
            guard inPackage(resolved.path) || (resolved.executable && (names(full) || names(resolved.path))) else { return nil }
            return Launch(tool: full, runtime: executable.isEmpty ? nil : executable, throughShell: Self.shells.contains(runtime))
        }

        static func script(of process: TerminalProcess) -> (String, String)? {
            guard let first = process.arguments.first else { return nil }
            let runtime = [first, process.executable].map { unwrapped(($0 as NSString).lastPathComponent) }.first { runtimes[$0] != nil }
            guard let runtime, let subcommands = runtimes[runtime] else { return nil }
            var words = process.arguments.dropFirst().filter { !$0.hasPrefix("-") }[...]
            if let word = words.first, subcommands.contains(word) { words = words.dropFirst() }
            return words.first.map { ($0, runtime) }
        }

        public func mentions(_ process: TerminalProcess) -> Bool {
            let texts = [process.name, process.executable] + process.arguments.prefix(3)
            return texts.contains { text in
                let words = (text as NSString).lastPathComponent.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                return words.contains { $0 == command } || inPackage(text)
            }
        }

        func setup(_ process: TerminalProcess, home: String) -> String? {
            guard !usesProfile(process) else { return nil }
            let raw = process.environment[setupVariable].flatMap { $0.isEmpty ? nil : $0 } ?? defaultSetup
            return FolderPath.resolve(raw, home: home, relativeTo: process.directory ?? "/")
        }

        func usesProfile(_ process: TerminalProcess) -> Bool {
            let flagged = process.arguments.contains { argument in profileFlags.contains { argument == $0 || argument.hasPrefix($0 + "=") } }
            return flagged || profileVariables.contains { !(process.environment[$0] ?? "").isEmpty }
        }

        public func isOwnName(_ name: String) -> Bool {
            Self.unwrapped(name) == command || (anyVersionName && Self.isVersion(name))
        }

        static func isVersion(_ name: String) -> Bool {
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        }
    }

    public static func mayLookAt(_ path: String, home: String) -> Bool {
        let guarded = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { (home as NSString).appendingPathComponent($0) + "/" } + ["/Volumes/", "/Network/", "/net/", "/automount/"]
        return path.hasPrefix("/") && !guarded.contains { path.hasPrefix($0) }
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
            return candidates.compactMap(\.setup).filter { seen.insert($0).inserted }
        }
    }

    public static func classify(
        _ processes: [TerminalProcess], rule: Rule, home: String, parent: (Int) -> Int? = { _ in nil }, resolve: (String) -> Resolved? = { _ in nil }
    ) -> Found {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var launches: [Int: Launch] = [:]
        for process in processes where process.argumentsReadable {
            if let launch = rule.launch(of: process, resolve: resolve) { launches[process.pid] = launch }
        }
        func ancestors(of pid: Int) -> [Int] {
            var found: [Int] = []
            var next = byPid[pid]?.parent ?? parent(pid)
            while let at = next, at > 1, found.count < 64 {
                found.append(at)
                next = byPid[at]?.parent ?? parent(at)
            }
            return found
        }
        let wrappers = Set(launches.filter(\.value.throughShell).keys)
        let wrapping = Set(launches.keys.flatMap(ancestors(of:))).intersection(wrappers)
        for pid in wrapping { launches[pid] = nil }
        let agents = Set(launches.keys)
        func startedByAgent(_ pid: Int) -> Bool { ancestors(of: pid).contains(where: agents.contains) }
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
                setup: rule.setup(process, home: home), tty: process.tty, tool: launches[process.pid]?.tool,
                runtime: launches[process.pid]?.runtime))
        }
        return Found(candidates: candidates, unreadable: unreadable)
    }
}
