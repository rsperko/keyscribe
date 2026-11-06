import Foundation

public enum AgentConnectorStatus: Equatable, Sendable {
    case notInstalled
    case ready
    case outdated(installed: String)
    case disabled
    case unknown
}
