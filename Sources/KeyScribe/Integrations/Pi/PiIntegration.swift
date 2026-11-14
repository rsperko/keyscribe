import KeyScribeKit

extension AgentIntegration {
    static let pi = AgentIntegration(
        kind: .pi, discovery: { _, processes in PiDiscovery(processes: { processes.found(.pi) }) },
        connector: { PiConnector(agentsDir: $0, pluginName: $1, surfaces: $2) })
}
