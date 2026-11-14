import Foundation
import KeyScribeKit

public enum AgentHostScan: Equatable, Sendable {
    case found([AgentSession])
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

    public init(bundle: String, pid: Int, name: String) {
        self.bundle = bundle
        self.pid = pid
        self.name = name
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
    var watchedFolders: [URL] { get }
    func scan() async -> AgentHostScan
    func open(_ location: AgentHostLocation) async -> AgentHostOpen
    func front(among locations: [AgentHostLocation]) async -> AgentHostFront
    func deliver(_ text: String, request: String, to location: AgentHostLocation) async -> AgentHostDelivery
}

extension AgentHost {
    public var watchedFolders: [URL] { [] }
    public func open(_ location: AgentHostLocation) async -> AgentHostOpen { .unsupported }
    public func front(among locations: [AgentHostLocation]) async -> AgentHostFront { .unsupported }
    public func deliver(_ text: String, request: String, to location: AgentHostLocation) async -> AgentHostDelivery { .unsupported }
}

public struct AgentHostIntegration: Sendable {
    public var kind: AgentKind
    public var make: @MainActor @Sendable () -> any AgentHost

    public init(kind: AgentKind, make: @escaping @MainActor @Sendable () -> any AgentHost) {
        self.kind = kind
        self.make = make
    }
}

@MainActor
final class HostDiscovery: AgentDiscovery {
    static let fallbackInterval: TimeInterval = 10

    let kind: AgentKind
    let host: any AgentHost
    private let now: () -> Date
    private var last: (at: Date, scan: AgentScan)?
    private var answered = false

    init(_ integration: AgentHostIntegration, now: @escaping () -> Date = Date.init) {
        kind = integration.kind
        host = integration.make()
        self.now = now
    }

    var watchedFolders: [URL] { host.isEnabled ? host.watchedFolders : [] }

    func scan(rereadingTitles: Bool) async -> AgentScan {
        guard host.isEnabled else {
            last = nil
            answered = false
            return .found([])
        }
        if !rereadingTitles, let last, now().timeIntervalSince(last.at) < Self.fallbackInterval { return last.scan }
        let started = now()
        let scan = await fresh()
        last = (started, scan)
        if case .found = scan, host.isEnabled { answered = true }
        return scan
    }

    private func fresh() async -> AgentScan {
        switch await host.scan() {
        case .found(let sessions):
            var seen: Set<String> = []
            return .found(sessions.compactMap { session in
                guard let location = session.host, location.host == kind.id, seen.insert(location.conversationKey).inserted else { return nil }
                var owned = session
                owned.agent = kind.id
                owned.id = location.conversationKey
                owned.pid = nil
                return owned
            })
        case .unreadable(let why):
            return .unreadable(why)
        }
    }

    func stillRunning(_ remembered: RememberedName) -> Bool { !host.isEnabled || !answered }
}
