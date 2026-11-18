import Foundation
import KeyScribeKit

public enum AgentHostScan: Equatable, Sendable {
    case found(
        [AgentSession], titles: [String: String] = [:], shownInstead: [String: String] = [:], carried: Set<AgentHostLocation> = [],
        problem: String? = nil)
    case unreadable(String)
}

public enum AgentHostOpen: Equatable, Sendable {
    case opened
    case requested
    case failed
    case unsupported
}

public struct AgentHostApp: Equatable, Sendable {
    public var bundle: String
    public var pid: Int
    public var name: String
    public var window: String?
    public var path: String?
    public var instance: String?

    public init(bundle: String, pid: Int, name: String, window: String? = nil, path: String? = nil, instance: String? = nil) {
        self.bundle = bundle
        self.pid = pid
        self.name = name
        self.window = window
        self.path = path
        self.instance = instance
    }
}

public struct AgentHostCopy: Equatable, Sendable {
    public var name: String
    public var instance: String
    public var enrolled: Bool

    public init(name: String, instance: String, enrolled: Bool) {
        self.name = name
        self.instance = instance
        self.enrolled = enrolled
    }
}

public enum AgentHostFront: Equatable, Sendable {
    case shown(AgentHostLocation, in: AgentHostApp)
    case unknown
    case unsupported
}

public enum AgentHostDelivery: Equatable, Sendable {
    case accepted
    case queued
    case uncertain
    case refused(String)
    case unsupported
}

@MainActor
public protocol AgentHost: AnyObject {
    var isEnabled: Bool { get }
    var takesImages: Bool { get }
    var identityKeys: [String] { get }
    func location(in environment: [String: String]) -> AgentHostLocation?
    func scan() async -> AgentHostScan
    func open(_ location: AgentHostLocation, stillWanted: @escaping @MainActor () -> Bool) async -> AgentHostOpen
    func front(among locations: [AgentHostLocation], reported: AgentHostLocation?, in app: AgentHostApp?) async -> AgentHostFront
    func focusedWindow() -> AgentHostApp?
    func copyInFront() -> AgentHostCopy?
    func deliver(_ text: String, images: [String], request: String, to location: AgentHostLocation) async -> AgentHostDelivery
    func rename(_ location: AgentHostLocation, to name: String) async -> Bool
}

extension AgentHost {
    public var takesImages: Bool { false }
    public var identityKeys: [String] { [] }
    public func location(in environment: [String: String]) -> AgentHostLocation? { nil }
    public func open(_ location: AgentHostLocation, stillWanted: @escaping @MainActor () -> Bool) async -> AgentHostOpen { .unsupported }
    public func front(among locations: [AgentHostLocation], reported: AgentHostLocation?, in app: AgentHostApp?) async -> AgentHostFront {
        .unsupported
    }
    public func focusedWindow() -> AgentHostApp? { nil }
    public func copyInFront() -> AgentHostCopy? { nil }
    public func deliver(_ text: String, images: [String], request: String, to location: AgentHostLocation) async -> AgentHostDelivery {
        .unsupported
    }
    public func rename(_ location: AgentHostLocation, to name: String) async -> Bool { false }
}

public struct AgentHostIntegration: Sendable {
    public var kind: AgentKind
    public var make: @MainActor @Sendable () -> any AgentHost
    var connector: (@MainActor @Sendable (_ agentsDir: URL, _ pluginName: String) -> any AgentConnector)?
    var withSetups: (@MainActor @Sendable (ConnectorSetupRegistry) -> any AgentHost)?
    public var folderVariable: String?

    public init(kind: AgentKind, make: @escaping @MainActor @Sendable () -> any AgentHost) {
        self.kind = kind
        self.make = make
    }

    func bound(to setups: ConnectorSetupRegistry) -> AgentHostIntegration {
        guard let withSetups else { return self }
        var bound = self
        bound.make = { withSetups(setups) }
        return bound
    }
}

@MainActor
final class HostDiscovery: AgentDiscovery {
    static let fallbackInterval: TimeInterval = 10
    static let idleInterval: TimeInterval = 300

    let kind: AgentKind
    let host: any AgentHost
    private let allowed: @MainActor () -> Bool
    private let now: () -> Date
    private var last: (at: Date, scan: AgentScan)?
    private var answered = false
    private var wanted = false
    private var prompting: [String: Date] = [:]
    private var answeredSinceList: Set<String> = []
    private var turning: [String: (working: Bool, at: Date)] = [:]
    private var reportsTurns: Set<String> = []

    init(_ integration: AgentHostIntegration, allowed: @escaping @MainActor () -> Bool, now: @escaping () -> Date = Date.init) {
        kind = integration.kind
        host = integration.make()
        self.allowed = allowed
        self.now = now
    }

    var isEnabled: Bool { allowed() && host.isEnabled }

    func want() { wanted = true }

    func observe(_ event: AgentEvent) {
        switch event {
        case .hello(let hello):
            prompt(hello.session, open: hello.waiting != nil)
            if hello.reportsTurn, hello.features.contains("readiness") {
                reportsTurns.insert(hello.session)
                turning[hello.session] = (!hello.knownIdle, now())
            } else {
                reportsTurns.remove(hello.session)
                turning[hello.session] = nil
            }
        case .waiting(let session, let prompt): self.prompt(session, open: prompt != nil)
        case .turnStarted(let session, _, _): if reportsTurns.contains(session) { turning[session] = (true, now()) }
        case .turnComplete(let session, _, _, _):
            prompt(session, open: false)
            if reportsTurns.contains(session) { turning[session] = (false, now()) }
        default: break
        }
    }

    private func prompt(_ session: String, open: Bool) {
        if open {
            if prompting[session] == nil { prompting[session] = now() }
            answeredSinceList.remove(session)
        } else if prompting.removeValue(forKey: session) != nil {
            answeredSinceList.insert(session)
        }
    }

    func retire(sessions: Set<String>) {
        prompting = prompting.filter { !sessions.contains($0.key) }
        answeredSinceList.subtract(sessions)
        turning = turning.filter { !sessions.contains($0.key) }
        reportsTurns.subtract(sessions)
    }

    private func withPrompts(_ scan: AgentScan) -> AgentScan {
        guard case .found(let sessions, let extras) = scan, !prompting.isEmpty || !answeredSinceList.isEmpty || !turning.isEmpty else { return scan }
        return .found(sessions.map { session in
            var shown = session
            if prompting[session.id] != nil {
                shown.state = .userDialog
            } else if let turn = turning[session.id] {
                shown.state = turn.working ? .working : .idle
            } else if answeredSinceList.contains(session.id), [.waitingApproval, .waitingQuestion, .userDialog].contains(session.state) {
                shown.state = .working
            }
            return shown
        }, extras)
    }

    func expect() { last = nil }

    func scan(rereadingTitles: Bool) async -> AgentScan {
        guard allowed() else {
            last = nil
            answered = false
            return .found([])
        }
        guard host.isEnabled else {
            last = nil
            return .found([], AgentScanExtras(problem: "\(kind.displayName) isn\u{2019}t installed on this Mac. Install it, or turn this off."))
        }
        if let last, now().timeIntervalSince(last.at) < interval(after: last.scan) { return withPrompts(last.scan) }
        wanted = false
        let started = now()
        let scan = await fresh()
        last = (started, scan)
        if case .found(let sessions, _) = scan {
            answeredSinceList = []
            let idle = Set(sessions.filter { $0.state == .idle }.map(\.id))
            let listed = Set(sessions.map(\.id))
            prompting = prompting.filter { listed.contains($0.key) && ($0.value > started || !idle.contains($0.key)) }
            turning = turning.filter { listed.contains($0.key) && $0.value.at > started }
            if isEnabled { answered = true }
        }
        return withPrompts(scan)
    }

    private func interval(after scan: AgentScan) -> TimeInterval {
        guard case .found = scan, !wanted else { return Self.fallbackInterval }
        return Self.idleInterval
    }

    private func fresh() async -> AgentScan {
        switch await host.scan() {
        case .found(let sessions, let titles, let shownInstead, let carried, let problem):
            var seen: Set<String> = []
            var placed: [String: AgentPlace] = [:]
            let owned: [AgentSession] = sessions.compactMap { session in
                guard let location = session.host, location.host == kind.id, seen.insert(location.conversationKey).inserted else { return nil }
                var owned = session
                owned.agent = kind.id
                owned.id = location.conversationKey
                owned.pid = nil
                let title = titles[location.conversationKey] ?? titles[location.native]
                let instead = shownInstead[location.conversationKey] ?? shownInstead[location.native]
                let labels = [
                    title.map { AgentPlace.Label(text: $0, level: .title, container: location.conversationKey, surface: kind.displayName, term: "title") },
                    instead.map {
                        AgentPlace.Label(
                            text: $0, level: .title, container: location.conversationKey, surface: kind.displayName, term: "title", onlyAfterVerb: true)
                    },
                ].compactMap { $0 }
                if !labels.isEmpty {
                    placed[AgentSessionID.make(agent: kind.id, native: owned.id)] = AgentPlace(
                        surface: kind.displayName, labels: labels, containers: [location.conversationKey])
                }
                return owned
            }
            let unread = Set(carried.filter { $0.host == kind.id }.map(\.conversationKey))
            return .found(owned, AgentScanExtras(
                problem: problem, carried: unread.intersection(owned.map(\.id)), places: placed,
                listed: Set(owned.map { AgentSessionID.make(agent: kind.id, native: $0.id) })))
        case .unreadable(let why):
            return .unreadable(why)
        }
    }

    func stillRunning(_ remembered: RememberedName) -> Bool { !isEnabled || !answered }
}
