import Foundation
import KeyScribeKit

struct AgentPlaceQuery: Equatable, Sendable {
    var id: String
    var agent: String
    var native: String
    var pid: Int
}

enum AgentPlaceAnswer: Equatable, Sendable {
    case found(AgentPlace)
    case absent
    case unknown
}

protocol AgentPlaceReading: Sendable {
    func read(_ queries: [AgentPlaceQuery]) -> [String: AgentPlaceAnswer]
}

struct HerdrPlaceReader: AgentPlaceReading {
    var environment: @Sendable (Int) -> [String: String]? = { pid in
        SystemTerminalFacts.arguments(
            of: pid, keeping: [HerdrPlaces.socketKey, HerdrPlaces.paneKey, HerdrPlaces.executableKey])?.environment
    }
    var serverExecutable: @Sendable () -> String? = {
        SystemTerminalFacts().processes(named: HerdrPlaces.processName)?
            .first { $0.arguments.dropFirst().first == "server" && !$0.executable.isEmpty }?.executable
    }
    var run: @Sendable ([String]) -> (status: Int32, output: String) = { ToolCLI.run($0, timeout: 3) }

    func read(_ queries: [AgentPlaceQuery]) -> [String: AgentPlaceAnswer] {
        var answers: [String: AgentPlaceAnswer] = [:]
        var bySocket: [String: [(query: AgentPlaceQuery, pane: String?)]] = [:]
        var executable: String?
        for query in queries {
            guard let environment = environment(query.pid) else {
                answers[query.id] = .unknown
                continue
            }
            guard let socket = environment[HerdrPlaces.socketKey], !socket.isEmpty else {
                answers[query.id] = .absent
                continue
            }
            executable = executable ?? environment[HerdrPlaces.executableKey].flatMap { $0.isEmpty ? nil : $0 }
            bySocket[socket, default: []].append((query, environment[HerdrPlaces.paneKey]))
        }
        guard !bySocket.isEmpty else { return answers }
        guard let herdr = executable ?? serverExecutable() else {
            for member in bySocket.values.flatMap({ $0 }) { answers[member.query.id] = .unknown }
            return answers
        }
        for (socket, members) in bySocket {
            let commands = HerdrPlaces.listCommands(socket: socket, executable: herdr)
            let panes = run(commands.panes), tabs = run(commands.tabs), workspaces = run(commands.workspaces)
            guard panes.status == 0, tabs.status == 0, workspaces.status == 0,
                  let listing = HerdrPlaces.listing(panes: panes.output, tabs: tabs.output, workspaces: workspaces.output)
            else {
                for member in members { answers[member.query.id] = .unknown }
                continue
            }
            for member in members {
                let association = HerdrPlaces.place(agent: member.query.agent, native: member.query.native, in: listing, socket: socket) {
                    member.pane.map { HerdrPlaces.currentPane(run(HerdrPlaces.currentPaneCommand(socket: socket, pane: $0, executable: herdr))) }
                }
                answers[member.query.id] = switch association {
                case .found(let place): .found(place)
                case .absent: .absent
                case .unresolved: .unknown
                }
            }
        }
        return answers
    }
}

@MainActor
final class AgentPlaceTracker {
    static let busyInterval: TimeInterval = 3
    static let quietInterval: TimeInterval = 10

    private(set) var places: [String: AgentPlace] = [:]
    private(set) var checked: Set<String> = []
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
        let interval = places.isEmpty ? Self.quietInterval : Self.busyInterval
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
                let answers = wanted.isEmpty ? [:] : await Task.detached { reader.read(wanted) }.value
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

    private func apply(_ answers: [String: AgentPlaceAnswer], listed: Set<String>) {
        var next = places.filter { listed.contains($0.key) }
        var nowChecked = checked.intersection(listed)
        for (id, answer) in answers {
            switch answer {
            case .found(let place):
                next[id] = place
                nowChecked.insert(id)
            case .absent:
                next[id] = nil
                nowChecked.insert(id)
            case .unknown:
                nowChecked.remove(id)
            }
        }
        guard next != places || nowChecked != checked else { return }
        places = next
        checked = nowChecked
        onChange?()
    }
}
