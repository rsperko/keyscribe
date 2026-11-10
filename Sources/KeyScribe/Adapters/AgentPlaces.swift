import Foundation
import KeyScribeKit

struct AgentPlaceQuery: Equatable, Sendable {
    var id: String
    var agent: String
    var native: String
    var pid: Int
    var environment: [String: String] = [:]
    var placed = false
}

enum AgentPlaceAnswer: Equatable, Sendable {
    case found(AgentPlace)
    case absent
    case unknown
}

protocol AgentPlaceReading: Sendable {
    func read(_ queries: [AgentPlaceQuery]) async -> [String: AgentPlaceAnswer]
}

struct CombinedPlaceReader: AgentPlaceReading {
    var readers: [any AgentPlaceReading]

    func read(_ queries: [AgentPlaceQuery]) async -> [String: AgentPlaceAnswer] {
        var answers: [[String: AgentPlaceAnswer]] = []
        for reader in readers { answers.append(await reader.read(queries)) }
        return Dictionary(uniqueKeysWithValues: queries.map { query in
            (query.id, Self.merge(answers.map { $0[query.id] ?? .absent }))
        })
    }

    static func merge(_ answers: [AgentPlaceAnswer]) -> AgentPlaceAnswer {
        if answers.contains(.unknown) { return .unknown }
        let places = answers.compactMap { if case .found(let place) = $0 { place } else { nil } }
        guard let first = places.first else { return .absent }
        return .found(AgentPlace(
            surface: first.surface, labels: places.flatMap(\.labels),
            containers: places.flatMap(\.containers).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }))
    }
}

struct TerminalPlaceReader: AgentPlaceReading {
    var walk: @Sendable (Int, [String: String], TerminalFacts) -> TerminalPlaceWalk? = {
        TerminalPlaces.walk(agent: $0, facts: $2.reporting($1, for: $0))
    }
    var facts: @Sendable () -> TerminalFacts = { CachedTerminalFacts(SystemTerminalFacts()) }
    let answered = HostAnswers()

    final class HostAnswers: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: String] = [:]
        func remember(_ host: String, _ answer: String) { lock.withLock { answers[host] = answer } }
        func last(_ host: String) -> String? { lock.withLock { answers[host] } }
    }
    var script: @Sendable (_ app: String, _ pid: Int, _ body: String) async -> TerminalRead = {
        await TerminalScripting.read($0, pid: $1, body: $2, asking: {}, mayAsk: false)
    }

    func read(_ queries: [AgentPlaceQuery]) async -> [String: AgentPlaceAnswer] {
        let shared = facts()
        let walks = queries.map { (query: $0, walk: walk($0.pid, $0.environment, shared)) }
        var scripted: [String: String] = [:]
        for host in Set(walks.compactMap { $0.walk?.host.map { "\($0.route)\t\($0.app)\t\($0.pid)" } }).sorted() {
            let parts = host.split(separator: "\t").map(String.init)
            guard parts.count == 3, let route = ScriptedTerminalRoute.route(named: parts[0]), let body = route.placeScript, let pid = Int(parts[2])
            else { continue }
            switch await script(parts[1], pid, body) {
            case .value(let answer):
                scripted[host] = answer
                answered.remember(host, answer)
            case .failed: scripted[host] = answered.last(host)
            case .notAllowed: break
            }
        }
        return Dictionary(uniqueKeysWithValues: walks.map { item in
            let unreadable: AgentPlaceAnswer = item.query.placed ? .unknown : .absent
            guard let walk = item.walk else { return (item.query.id, unreadable) }
            if walk.layers.contains(where: \.unresolved) { return (item.query.id, unreadable) }
            var layers = walk.layers
            if let host = walk.host, let route = ScriptedTerminalRoute.route(named: host.route),
               let answer = scripted["\(host.route)\t\(host.app)\t\(host.pid)"],
               let outer = route.places(answer: answer, ttys: host.ttys) {
                layers.append(outer)
            }
            let labels = layers.flatMap(\.labels), containers = layers.flatMap(\.containers)
            guard !containers.isEmpty, let surface = walk.surface else { return (item.query.id, .absent) }
            return (item.query.id, .found(AgentPlace(surface: surface, labels: labels, containers: containers)))
        })
    }
}

@MainActor
final class AgentPlaceTracker {
    static let busyInterval: TimeInterval = 3
    static let quietInterval: TimeInterval = 10

    private(set) var places: [String: AgentPlace] = [:]
    private(set) var checked: Set<String> = []
    private(set) var attempted: Set<String> = []
    private(set) var failingSince: [String: Date] = [:]
    var onChange: (() -> Void)?
    private let reader: any AgentPlaceReading
    private let now: () -> Date
    private let queries: () -> [AgentPlaceQuery]
    private var task: Task<Void, Never>?
    private var again = false
    private var lastRead = Date.distantPast
    private var asked: Set<String> = []

    init(reader: any AgentPlaceReading, now: @escaping () -> Date = Date.init, queries: @escaping () -> [AgentPlaceQuery]) {
        self.reader = reader
        self.now = now
        self.queries = queries
    }

    var reading: Task<Void, Never>? { task }

    func tick() {
        let interval = places.values.contains { !$0.labels.isEmpty } ? Self.busyInterval : Self.quietInterval
        if now().timeIntervalSince(lastRead) >= interval { request() }
    }

    func notice(_ ids: Set<String>) {
        if !ids.isSubset(of: asked) { request() }
    }

    func request() {
        if task != nil {
            again = true
            return
        }
        task = Task { @MainActor [weak self] in
            repeat {
                guard let self else { return }
                self.again = false
                let wanted = self.queries()
                self.asked = Set(wanted.map(\.id))
                self.lastRead = self.now()
                let reader = self.reader
                let answers = wanted.isEmpty ? [:] : await Task.detached { await reader.read(wanted) }.value
                self.apply(answers, listed: self.asked)
            } while self?.again == true
            self?.task = nil
        }
    }

    func stop() {
        task?.cancel()
        onChange = nil
    }

    func unchecked(_ ids: some Sequence<String>) -> Set<String> {
        Set(ids).subtracting(checked)
    }

    func unattempted(_ ids: some Sequence<String>) -> Set<String> {
        Set(ids).subtracting(attempted)
    }

    private func apply(_ answers: [String: AgentPlaceAnswer], listed: Set<String>) {
        var next = places.filter { listed.contains($0.key) }
        let nowChecked = checked.intersection(listed).union(answers.filter { $0.value != .unknown }.keys)
        let nowAttempted = attempted.intersection(listed).union(answers.keys)
        var failing = failingSince.filter { listed.contains($0.key) }
        for (id, answer) in answers {
            switch answer {
            case .found(let place):
                next[id] = place
                failing[id] = nil
            case .absent:
                next[id] = nil
                failing[id] = nil
            case .unknown:
                if failing[id] == nil { failing[id] = now() }
            }
        }
        guard next != places || nowChecked != checked || nowAttempted != attempted || failing != failingSince else { return }
        places = next
        checked = nowChecked
        attempted = nowAttempted
        failingSince = failing
        onChange?()
    }
}
