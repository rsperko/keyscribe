import KeyScribeKit

extension AgentIntegration {
    static let claude = AgentIntegration(
        kind: .claude, discovery: { ClaudeDiscovery(setups: $0, processes: $1) },
        connector: { ClaudeConnector(agentsDir: $0, pluginName: $1, surfaces: $2) })
}
