import Darwin
import Foundation
import KeyScribeKit

final class AgentProcessTable: @unchecked Sendable {
    private var rules: [AgentProcesses.Rule]
    private let maxAge: TimeInterval
    private let home: String
    private let now: @Sendable () -> Date
    private let isRunning: @Sendable (Int) -> Bool
    private let list: @Sendable ([AgentProcesses.Rule]) -> [TerminalProcess]?
    private let resolve: @Sendable (String) -> AgentProcesses.Resolved?
    private let tools: ToolEnvironment?
    private let lock = NSLock()
    private var listed: (at: Date, generation: Int, agents: Set<String>, processes: [TerminalProcess]?, found: [String: AgentProcesses.Found])?
    private var listings = 0
    private var seen: [String: [AgentCandidate]] = [:]

    init(
        rules: [AgentProcesses.Rule] = [], maxAge: TimeInterval = 5, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        now: @escaping @Sendable () -> Date = Date.init, isRunning: @escaping @Sendable (Int) -> Bool = ProcessStart.isRunning(pid:),
        resolve: @escaping @Sendable (String) -> AgentProcesses.Resolved? = AgentProcessTable.resolve, tools: ToolEnvironment? = nil,
        list: @escaping @Sendable ([AgentProcesses.Rule]) -> [TerminalProcess]?
    ) {
        self.resolve = resolve
        self.tools = tools
        self.rules = rules
        self.maxAge = maxAge
        self.home = home
        self.now = now
        self.isRunning = isRunning
        self.list = list
    }

    func found(_ rule: AgentProcesses.Rule, reusing: Bool = false) -> AgentProcesses.Found {
        let (listing, processes, known): (Int, [TerminalProcess]?, AgentProcesses.Found?) = lock.withLock {
            if !rules.contains(where: { $0.agent == rule.agent }) { rules.append(rule) }
            if let listed, listed.agents.contains(rule.agent), reusing || now().timeIntervalSince(listed.at) < maxAge {
                return (listed.generation, listed.processes, listed.found[rule.agent])
            }
            let fresh = list(rules)
            listings += 1
            listed = (now(), listings, Set(rules.map(\.agent)), fresh, [:])
            return (listings, fresh, nil)
        }
        if let known { return known }
        let earlier = lock.withLock { seen[rule.agent] ?? [] }.filter { isRunning($0.pid) }
        var found: AgentProcesses.Found
        if let processes {
            found = AgentProcesses.classify(processes, rule: rule, home: home, parent: SystemTerminalFacts.parent(of:), resolve: resolve)
            found.candidates = found.candidates.map { candidate in
                var canonical = candidate
                canonical.setup = candidate.setup.map { ConnectorFolders.canonical(URL(fileURLWithPath: $0, isDirectory: true)).path }
                return canonical
            }
            let unread = Set(found.unreadable)
            let fresh = Set(found.candidates.map(\.pid))
            found.candidates += earlier.filter { unread.contains($0.pid) && !fresh.contains($0.pid) }
        } else {
            found = AgentProcesses.Found(candidates: earlier, stale: true)
        }
        let candidates = found.candidates
        lock.withLock {
            seen[rule.agent] = candidates
            if listed?.generation == listing { listed?.found[rule.agent] = found }
        }
        if let processes { tools?.record(agent: rule.agent, candidates: candidates, sightings: Self.sightings(processes, rule: rule, found: found, resolve: resolve)) }
        return found
    }

    static func sightings(
        _ processes: [TerminalProcess], rule: AgentProcesses.Rule, found: AgentProcesses.Found,
        resolve: (String) -> AgentProcesses.Resolved? = AgentProcessTable.resolve
    ) -> [DiscoveryReport.Sighting] {
        let matched = Dictionary(found.candidates.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return processes.filter { matched[$0.pid] != nil || rule.mentions($0) }.map { process in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let files = process.arguments.prefix(3).filter { $0.hasPrefix("/") && !$0.contains("\n") }.compactMap { path in
                AgentProcesses.mayLookAt(path, home: home) ? (resolve(path) != nil ? path : nil) : path + " (not looked at)"
            }
            let paths = [process.executable] + files + [matched[process.pid]?.tool, matched[process.pid]?.runtime].compactMap { $0 }
            var unique: [String] = []
            for path in paths where !path.isEmpty && !unique.contains(path) { unique.append(path) }
            return DiscoveryReport.Sighting(
                pid: process.pid, name: process.name, paths: process.argumentsReadable ? unique : ["(arguments unreadable)"],
                matched: matched[process.pid] != nil, setup: matched[process.pid]?.setup)
        }
    }

    @Sendable static func resolve(_ path: String) -> AgentProcesses.Resolved? {
        resolve(path, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    static func resolve(_ path: String, home: String) -> AgentProcesses.Resolved? {
        guard AgentProcesses.mayLookAt(path, home: home) else { return nil }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard AgentProcesses.mayLookAt(real, home: home),
              (try? FileManager.default.attributesOfItem(atPath: real))?[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return AgentProcesses.Resolved(path: real, executable: FileManager.default.isExecutableFile(atPath: real))
    }

    convenience init(surfaces: ResolvedSurfaces, tools: ToolEnvironment = .shared) {
        let lister = AgentProcessLister(keeping: surfaces.environmentKeys)
        self.init(tools: tools, list: { lister.list($0) })
    }
}

final class AgentProcessLister: @unchecked Sendable {
    private struct Key: Hashable {
        var pid: Int32
        var started: Int?
        var name: String
    }

    private enum Seen {
        case skip
        case unreadable
        case mention(TerminalProcess)
        case launch
    }

    private let keys: Set<String>
    private let resolve: @Sendable (String) -> AgentProcesses.Resolved?
    private let lock = NSLock()
    private var cache: [Key: Seen] = [:]
    private var cachedFor: [String] = []

    init(keeping keys: Set<String>, resolve: @escaping @Sendable (String) -> AgentProcesses.Resolved? = AgentProcessTable.resolve) {
        self.keys = keys
        self.resolve = resolve
    }

    static func environmentKeys(keeping keys: Set<String>, rules: [AgentProcesses.Rule]) -> Set<String> {
        keys.union(rules.flatMap { [$0.setupVariable] + $0.profileVariables })
    }

    func list(_ rules: [AgentProcesses.Rule]) -> [TerminalProcess]? {
        guard let own = SystemTerminalFacts.ownProcesses() else { return nil }
        let facts = SystemTerminalFacts(environmentKeys: Self.environmentKeys(keeping: keys, rules: rules))
        let agents = rules.map(\.agent)
        let known: [Key: Seen] = lock.withLock { cachedFor == agents ? cache : [:] }
        var next: [Key: Seen] = [:]
        var found: [TerminalProcess] = []
        for entry in own {
            let key = Key(pid: entry.pid, started: entry.started, name: entry.name)
            let seen = known[key] ?? look(entry, rules: rules)
            next[key] = seen
            switch seen {
            case .skip: continue
            case .mention(let light): found.append(light)
            case .unreadable, .launch:
                guard var process = facts.process(Int(entry.pid)) else { continue }
                if process.executable.isEmpty { process.executable = entry.name }
                found.append(process)
            }
        }
        lock.withLock {
            cache = next
            cachedFor = agents
        }
        return found
    }

    private func look(_ entry: SystemTerminalFacts.Own, rules: [AgentProcesses.Rule]) -> Seen {
        guard let read = SystemTerminalFacts.arguments(of: Int(entry.pid), keeping: []) else {
            return rules.contains { $0.isOwnName(entry.name) } ? .unreadable : .skip
        }
        let light = TerminalProcess(
            pid: Int(entry.pid), parent: entry.parent, tty: nil, arguments: Array(read.arguments.prefix(8)), environment: [:],
            executable: read.executable.isEmpty ? entry.name : read.executable, app: nil,
            directory: SystemTerminalFacts.directory(of: Int(entry.pid)), startedAt: entry.started)
        if rules.contains(where: { $0.launch(of: light, resolve: resolve) != nil }) { return .launch }
        return rules.contains { $0.mentions(light) } ? .mention(light) : .skip
    }
}
