import Foundation
import KeyScribeKit

extension AgentIntegration {
    static let pi = AgentIntegration(
        kind: .pi,
        folderVariable: AgentProcesses.Rule.pi.setupVariable,
        discovery: { setups, processes in
            PiDiscovery(
                processes: { processes.found(.pi) },
                folder: { installation in setups.setups?.setups.first { $0.agent == AgentKind.pi.id && $0.installation == installation }?.folder },
                declared: {
                    ToolEnvironment.shared.folder(AgentProcesses.Rule.pi.setupVariable).flatMap { path in
                        FileManager.default.fileExists(atPath: path) ? ConnectorFolders.canonical(URL(fileURLWithPath: path, isDirectory: true)).path : nil
                    }
                })
        },
        connector: { PiConnector(agentsDir: $0, pluginName: $1, surfaces: $2) })
}
