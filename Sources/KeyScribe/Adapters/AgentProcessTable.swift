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
    private let lock = NSLock()
    private var listed: (at: Date, agents: Set<String>, processes: [TerminalProcess]?)?
    private var seen: [String: [AgentCandidate]] = [:]

    init(
        rules: [AgentProcesses.Rule] = [], maxAge: TimeInterval = 5, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        now: @escaping @Sendable () -> Date = Date.init, isRunning: @escaping @Sendable (Int) -> Bool = ProcessStart.isRunning(pid:),
        list: @escaping @Sendable ([AgentProcesses.Rule]) -> [TerminalProcess]?
    ) {
        self.rules = rules
        self.maxAge = maxAge
        self.home = home
        self.now = now
        self.isRunning = isRunning
        self.list = list
    }

    func found(_ rule: AgentProcesses.Rule) -> AgentProcesses.Found {
        let processes = lock.withLock {
            if !rules.contains(where: { $0.agent == rule.agent }) { rules.append(rule) }
            if let listed, listed.agents.contains(rule.agent), now().timeIntervalSince(listed.at) < maxAge { return listed.processes }
            let fresh = list(rules)
            listed = (now(), Set(rules.map(\.agent)), fresh)
            return fresh
        }
        let earlier = lock.withLock { seen[rule.agent] ?? [] }.filter { isRunning($0.pid) }
        var found: AgentProcesses.Found
        if let processes {
            found = AgentProcesses.classify(
                processes.filter { rule.mayBe(name: $0.name) }, rule: rule, home: home, parent: SystemTerminalFacts.parent(of:))
            found.candidates = found.candidates.map { candidate in
                var canonical = candidate
                canonical.setup = ConnectorFolders.canonical(URL(fileURLWithPath: candidate.setup, isDirectory: true)).path
                return canonical
            }
            let unread = Set(found.unreadable)
            let fresh = Set(found.candidates.map(\.pid))
            found.candidates += earlier.filter { unread.contains($0.pid) && !fresh.contains($0.pid) }
        } else {
            found = AgentProcesses.Found(candidates: earlier, stale: true)
        }
        let candidates = found.candidates
        lock.withLock { seen[rule.agent] = candidates }
        return found
    }

    convenience init(surfaces: ResolvedSurfaces) {
        self.init(list: { AgentProcessTable.list($0, keeping: surfaces.environmentKeys) })
    }

    static func list(_ rules: [AgentProcesses.Rule], keeping keys: Set<String>) -> [TerminalProcess]? {
        guard let pids = SystemTerminalFacts.allPids() else { return nil }
        let facts = SystemTerminalFacts(environmentKeys: keys.union(rules.map(\.setupVariable)))
        let uid = getuid()
        return pids.compactMap { pid -> TerminalProcess? in
            let name = SystemTerminalFacts.name(of: pid)
            guard rules.contains(where: { $0.mayBe(name: name) }),
                  let info = SystemTerminalFacts.info(Int(pid)), info.kp_eproc.e_ucred.cr_uid == uid
            else { return nil }
            guard var process = facts.process(Int(pid)) else { return nil }
            if process.executable.isEmpty { process.executable = name }
            return process
        }
    }
}
