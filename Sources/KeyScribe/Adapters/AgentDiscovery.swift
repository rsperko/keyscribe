import Foundation
import KeyScribeKit

enum AgentScan: Equatable, Sendable {
    case found([AgentSession])
    case unreadable(String)
}

@MainActor
protocol AgentDiscovery: AnyObject {
    var kind: AgentKind { get }
    func scan(rereadingTitles: Bool) async -> AgentScan
    func stillRunning(_ remembered: RememberedName) -> Bool
    func observe(_ event: AgentEvent)
    func retire()
}

extension AgentDiscovery {
    func observe(_ event: AgentEvent) {}
    func retire() {}
}
