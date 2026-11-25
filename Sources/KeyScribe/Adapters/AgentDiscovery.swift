import Foundation
import KeyScribeKit

struct AgentScanExtras: Equatable, Sendable {
    var candidates: [AgentCandidate] = []
    var setups: [String] = []
    var problem: String?
    var carried: Set<String> = []
    var places: [String: AgentPlace] = [:]
    var listed: Set<String> = []
}

enum AgentScan: Equatable, Sendable {
    case found([AgentSession], AgentScanExtras = AgentScanExtras())
    case unreadable(String)
}

@MainActor
protocol AgentDiscovery: AnyObject {
    var kind: AgentKind { get }
    var watchedFolders: [URL] { get }
    var nextLook: Date? { get }
    func scan(rereadingTitles: Bool) async -> AgentScan
    func stillRunning(_ remembered: RememberedName) -> Bool
    func observe(_ event: AgentEvent)
    func retire(sessions: Set<String>)
}

extension AgentDiscovery {
    var watchedFolders: [URL] { [] }
    var nextLook: Date? { nil }
    func observe(_ event: AgentEvent) {}
    func retire(sessions: Set<String>) {}
}
