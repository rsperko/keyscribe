import Foundation
import KeyScribeKit

public enum AgentHostScan: Equatable, Sendable {
    case found([AgentSession], titles: [String: String] = [:], shownInstead: [String: String] = [:])
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

    public init(bundle: String, pid: Int, name: String, window: String? = nil) {
        self.bundle = bundle
        self.pid = pid
        self.name = name
        self.window = window
    }
}

public enum AgentHostFront: Equatable, Sendable {
    case shown(AgentHostLocation, in: AgentHostApp)
    case elsewhere
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
    func front(among locations: [AgentHostLocation], reported: AgentHostLocation?) async -> AgentHostFront
    func deliver(_ text: String, images: [String], request: String, to location: AgentHostLocation) async -> AgentHostDelivery
}

extension AgentHost {
    public var takesImages: Bool { false }
    public var identityKeys: [String] { [] }
    public func location(in environment: [String: String]) -> AgentHostLocation? { nil }
    public func open(_ location: AgentHostLocation, stillWanted: @escaping @MainActor () -> Bool) async -> AgentHostOpen { .unsupported }
    public func front(among locations: [AgentHostLocation], reported: AgentHostLocation?) async -> AgentHostFront { .unsupported }
    public func deliver(_ text: String, images: [String], request: String, to location: AgentHostLocation) async -> AgentHostDelivery {
        .unsupported
    }
}

public struct AgentHostIntegration: Sendable {
    public var kind: AgentKind
    public var make: @MainActor @Sendable () -> any AgentHost
    var connector: (@MainActor @Sendable (_ agentsDir: URL, _ pluginName: String) -> any AgentConnector)?

    public init(kind: AgentKind, make: @escaping @MainActor @Sendable () -> any AgentHost) {
        self.kind = kind
        self.make = make
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

    init(_ integration: AgentHostIntegration, allowed: @escaping @MainActor () -> Bool, now: @escaping () -> Date = Date.init) {
        kind = integration.kind
        host = integration.make()
        self.allowed = allowed
        self.now = now
    }

    var isEnabled: Bool { allowed() && host.isEnabled }

    func want() { wanted = true }

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
        if let last, now().timeIntervalSince(last.at) < interval(after: last.scan) { return last.scan }
        wanted = false
        let started = now()
        let scan = await fresh()
        last = (started, scan)
        if case .found = scan, isEnabled { answered = true }
        return scan
    }

    private func interval(after scan: AgentScan) -> TimeInterval {
        guard case .found = scan, !wanted else { return Self.fallbackInterval }
        return Self.idleInterval
    }

    private func fresh() async -> AgentScan {
        switch await host.scan() {
        case .found(let sessions, let titles, let shownInstead):
            var seen: Set<String> = []
            var placed: [String: AgentPlace] = [:]
            let owned: [AgentSession] = sessions.compactMap { session in
                guard let location = session.host, location.host == kind.id, seen.insert(location.conversationKey).inserted else { return nil }
                var owned = session
                owned.agent = kind.id
                owned.id = location.conversationKey
                owned.pid = nil
                let labels = [
                    titles[location.native].map { AgentPlace.Label(text: $0, level: .title, container: location.conversationKey, surface: kind.displayName, term: "title") },
                    shownInstead[location.native].map {
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
            return .found(owned, AgentScanExtras(places: placed, listed: Set(owned.map { AgentSessionID.make(agent: kind.id, native: $0.id) })))
        case .unreadable(let why):
            return .unreadable(why)
        }
    }

    func stillRunning(_ remembered: RememberedName) -> Bool { !isEnabled || !answered }
}
