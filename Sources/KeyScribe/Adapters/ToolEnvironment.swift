import Darwin
import Foundation
import KeyScribeKit

final class ToolEnvironment: @unchecked Sendable {
    typealias Execute = @Sendable (
        _ argv: [String], _ timeout: TimeInterval, _ environment: [String: String], _ limit: Int, _ includeErrors: Bool
    ) -> ToolCLI.Ran

    enum Reason { case settings, miss }

    static let shared = ToolEnvironment()
    static let probeTimeout: TimeInterval = 5
    static let outputLimit = 256 * 1024
    static let settingsEvery: TimeInterval = 30
    static let busyRecheck: TimeInterval = 5
    static let missEvery: TimeInterval = 300
    static let quietAfterStart: TimeInterval = 60
    static let versionTimeout: TimeInterval = 10
    static let sightingLimit = 40

    let home: String
    let appEnvironment: [String: String]
    let shell: String
    private let execute: Execute
    private let now: @Sendable () -> Date
    private let makeNonce: @Sendable () -> String
    private let modified: @Sendable (String) -> Date?
    private let wait: @Sendable (TimeInterval) async -> Void
    private let isExecutable: @Sendable (String) -> Bool
    private var isBusy: @Sendable () async -> Bool = { false }
    private let lock = NSLock()
    private var probe: ShellProbeState = .notRun
    private var lastAttempt: Date?
    private var running: Task<Void, Never>?
    private var startedAt: Date?
    private var candidates: [String: [AgentCandidate]] = [:]
    private var seen: [String: [DiscoveryReport.Sighting]] = [:]
    private var checks: [String: (modified: Date?, result: ToolCheck)] = [:]
    private var keys: Set<String> = []
    private var observers: [@Sendable () -> Void] = []
    private var deferred: Task<Void, Never>?

    init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        appEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        shell: String? = nil,
        execute: @escaping Execute = { ToolCLI.executeGrouped($0, timeout: $1, environment: $2, includeErrors: $4, limit: $3) },
        now: @escaping @Sendable () -> Date = Date.init,
        makeNonce: @escaping @Sendable () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "") },
        modified: @escaping @Sendable (String) -> Date? = ToolEnvironment.modification(of:),
        wait: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.wait = wait
        self.isExecutable = isExecutable
        self.home = home
        self.appEnvironment = appEnvironment
        self.shell = shell ?? ShellEnvironment.shell(environment: appEnvironment, account: Self.accountShell())
        self.execute = execute
        self.now = now
        self.makeNonce = makeNonce
        self.modified = modified
    }

    var state: ShellProbeState { lock.withLock { probe } }
    var shellPath: [String]? { state.environment?.path }
    var appPath: [String] { (appEnvironment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") } }
    var isOn: Bool { lock.withLock { startedAt != nil } }

    func folder(_ key: String) -> String? { state.environment?.folder(key, home: home) }

    func waitWhile(_ busy: @escaping @Sendable () async -> Bool) {
        lock.withLock { isBusy = busy }
    }

    func observe(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { observers.append(handler) }
    }

    func turnedOn(_ on: Bool, keys wanted: Set<String> = []) {
        let previous: Task<Void, Never>? = lock.withLock {
            let previous = deferred
            deferred = nil
            if on {
                keys = wanted
                if startedAt == nil { startedAt = now() }
            } else {
                startedAt = nil
            }
            return previous
        }
        previous?.cancel()
        guard on else { return }
        let task = Task.detached { [self] in
            await self.wait(Self.quietAfterStart)
            let busy = self.lock.withLock { self.isBusy }
            while !Task.isCancelled, await busy() { await self.wait(Self.busyRecheck) }
            guard !Task.isCancelled else { return }
            await self.refresh(.miss)
        }
        lock.withLock { deferred = task }
    }

    func forgetFailedChecks() {
        lock.withLock { checks = checks.filter { $0.value.result.isWorking } }
    }

    @discardableResult
    func refresh(_ reason: Reason) async -> Bool {
        let (task, before): (Task<Void, Never>?, ShellEnvironment?) = lock.withLock {
            if let running { return (running, probe.environment) }
            guard let startedAt else { return (nil, nil) }
            let at = now()
            if reason == .miss, at.timeIntervalSince(startedAt) < Self.quietAfterStart { return (nil, nil) }
            if let lastAttempt, at.timeIntervalSince(lastAttempt) < (reason == .settings ? Self.settingsEvery : Self.missEvery) { return (nil, nil) }
            lastAttempt = at
            let before = probe
            let task = Task.detached { [self] in
                let read = self.readShell()
                let changed: Bool = self.lock.withLock {
                    switch (read, self.probe) {
                    case (.success(let environment), _): self.probe = .read(environment, at: self.now(), failure: nil)
                    case (.failure(let why), .read(let kept, let at, _)): self.probe = .read(kept, at: at, failure: why)
                    case (.failure(let why), _): self.probe = .failed(why)
                    }
                    self.running = nil
                    return self.probe.environment != before.environment
                }
                if changed { for observer in self.lock.withLock({ self.observers }) { observer() } }
            }
            running = task
            return (task, before.environment)
        }
        guard let task else { return false }
        await task.value
        return state.environment != before
    }

    private enum Read { case success(ShellEnvironment), failure(String) }

    private func readShell() -> Read {
        var reasons: [String] = []
        for flag in ShellEnvironment.flags(shell: shell) {
            let nonce = makeNonce()
            var environment = appEnvironment
            environment["TERM"] = "dumb"
            let ran = execute([shell, flag, ShellEnvironment.script(nonce: nonce)], Self.probeTimeout, environment, Self.outputLimit, false)
            if let found = ShellEnvironment.parse(ran.output, nonce: nonce, keys: lock.withLock { keys }) { return .success(found) }
            let name = (shell as NSString).lastPathComponent
            switch ran.end {
            case .timedOut(let seconds): reasons.append("\(name) \(flag) did not finish within \(seconds) seconds")
            case .couldNotStart(let why): reasons.append("\(name) could not be started: \(why)")
            case .signaled(let signal): reasons.append("\(name) \(flag) was stopped by signal \(signal)")
            case .exited(let status):
                reasons.append(ran.output.count >= Self.outputLimit
                    ? "\(name) \(flag) printed too much" : "\(name) \(flag) printed no environment (exit code \(status))")
            }
        }
        return .failure(reasons.joined(separator: "; "))
    }

    func record(agent: String, candidates found: [AgentCandidate], sightings: [DiscoveryReport.Sighting]) {
        lock.withLock {
            candidates[agent] = found
            seen[agent] = Array((sightings.filter(\.matched) + sightings.filter { !$0.matched }).prefix(Self.sightingLimit))
        }
    }

    func sightings(agent: String) -> [DiscoveryReport.Sighting] { lock.withLock { seen[agent] ?? [] } }

    func sessionTools(agent: String, setup: String?) -> [(tool: String, runtime: String?)] {
        let all = lock.withLock { candidates[agent] ?? [] }
        let mine = setup.map { folder in all.filter { $0.setup == folder } } ?? all
        let newestFirst: ([AgentCandidate]) -> [AgentCandidate] = { $0.sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) } }
        return (newestFirst(mine) + newestFirst(all)).compactMap { candidate in candidate.tool.map { ($0, candidate.runtime) } }
    }

    func search(program: String, agent: String, setup: String?, chosen: String?, extra: [String]) -> ToolSearch.Result {
        let sessions = sessionTools(agent: agent, setup: setup).map(\.tool)
        let places = ToolSearch.places(
            program: program, chosen: chosen, sessions: sessions, shellPath: shellPath, appPath: appPath, home: home, extra: extra)
        return ToolSearch.find(places, isExecutable: isExecutable)
    }

    func runEnvironment(tool: String, agent: String, base: [String: String]) -> [String: String] {
        var environment = base
        let runtime = sessionTools(agent: agent, setup: nil).first { $0.tool == tool }?.runtime
        environment["PATH"] = ToolSearch.runPath(tool: tool, runtime: runtime, shellPath: shellPath, appPath: appPath)
        return environment
    }

    func check(tool: String, agent: String) async -> ToolCheck {
        let stamp = modified(tool)
        if let known = lock.withLock({ checks[tool] }), known.modified == stamp { return known.result }
        let environment = runEnvironment(tool: tool, agent: agent, base: appEnvironment)
        let execute = execute
        let ran = await Task.detached { execute([tool, "--version"], Self.versionTimeout, environment, 64 * 1024, true) }.value
        let result = ToolCheck.judge(ran.end, output: ran.text)
        lock.withLock { checks[tool] = (stamp, result) }
        return result
    }

    func run(_ argv: [String], tool: String, agent: String) async -> ToolCLI.Ran {
        let environment = runEnvironment(tool: tool, agent: agent, base: appEnvironment)
        let execute = execute
        return await Task.detached { execute(argv, Self.versionTimeout, environment, Self.outputLimit, true) }.value
    }

    static func modification(of path: String) -> Date? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return (try? FileManager.default.attributesOfItem(atPath: real))?[.modificationDate] as? Date
    }

    private static func accountShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }
}
