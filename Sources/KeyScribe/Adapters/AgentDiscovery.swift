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
    func scan(rereadingTitles: Bool, reusingProcesses: Bool) async -> AgentScan
    func stillRunning(_ remembered: RememberedName) -> Bool
    func observe(_ event: AgentEvent)
    func retire(sessions: Set<String>)
    func follow(_ retitled: @escaping (_ native: String, _ title: AgentTitle) -> Void)
    func listed(_ native: String) -> AgentSession?
    func current(_ sessions: [AgentSession]) -> [AgentSession]
    func stop()
}

extension AgentDiscovery {
    func scan(rereadingTitles: Bool) async -> AgentScan { await scan(rereadingTitles: rereadingTitles, reusingProcesses: false) }
    var watchedFolders: [URL] { [] }
    func observe(_ event: AgentEvent) {}
    func retire(sessions: Set<String>) {}
    func follow(_ retitled: @escaping (_ native: String, _ title: AgentTitle) -> Void) {}
    func listed(_ native: String) -> AgentSession? { nil }
    func current(_ sessions: [AgentSession]) -> [AgentSession] { sessions }
    func stop() {}
}
