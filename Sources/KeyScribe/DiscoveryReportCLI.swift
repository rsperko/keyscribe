import Foundation
import KeyScribeKit

@MainActor
enum DiscoveryReportCLI {
    nonisolated static let flag = "--discovery-report"

    static func run(
        agent: String, folder: URL?, connectors: [any AgentConnector], agentsDir: URL, prepare: (String) async -> Void,
        declared: (String) -> String? = { ToolEnvironment.shared.folder($0) }
    ) async -> ConnectorCLI.Outcome {
        guard let connector = connectors.first(where: { $0.kind.id == agent }) else {
            return .init(code: 2, lines: ["discovery-report: no agent is named \u{201C}\(agent)\u{201D}. Known: \(connectors.map(\.kind.id).joined(separator: ", "))"])
        }
        await prepare(agent)
        await connector.rediscover()
        let registry = ConnectorSetupRegistry(directory: agentsDir)
        let named = connector.folderVariable.flatMap { variable in declared(variable).map { (variable, ConnectorFolders.canonical(URL(fileURLWithPath: $0, isDirectory: true))) } }
        let chosen = ConnectorFolders.canonical(folder ?? named?.1 ?? connector.defaultFolder)
        let defaultFolder = ConnectorFolders.canonical(connector.defaultFolder)
        let setup = ConnectorSetupModel(folder: chosen, isDefault: defaultFolder == chosen, connector: connector, registry: registry, retire: { _ in })
        await setup.refresh()
        var folders: [DiscoveryReport.Folder] = []
        for candidate in [chosen, defaultFolder] + (named.map { [$0.1] } ?? []) + connector.foundFolders.map(ConnectorFolders.canonical) where !folders.contains(where: { $0.path == candidate.path }) {
            var sources: [String] = []
            if candidate == chosen, folder != nil { sources.append("asked for") }
            if let named, candidate == named.1 { sources.append("\(named.0) in your login shell") }
            if candidate == defaultFolder { sources.append("default") }
            if registry.setups?.setup(agent: agent, folder: candidate.path) != nil { sources.append("connector installed") }
            if connector.foundFolders.contains(where: { ConnectorFolders.canonical($0) == candidate }) { sources.append("found on this Mac") }
            folders.append(.init(path: candidate.path, sources: sources))
        }
        let report = await setup.details(folders: folders)
        return .init(code: 0, lines: report.components(separatedBy: "\n") + ["", "State: \(ConnectorCLI.describe(setup.state, copy: connector.copy))"])
    }

    static func readLoginShell(keys: Set<String>) async {
        ToolEnvironment.shared.turnedOn(true, keys: keys)
        _ = await ToolEnvironment.shared.refresh(.settings)
    }

    static func prepare(rules: [AgentProcesses.Rule], surfaces: ResolvedSurfaces, keys: Set<String>) -> (String) async -> Void {
        { agent in
            await readLoginShell(keys: keys)
            guard let rule = rules.first(where: { $0.agent == agent }) else { return }
            _ = AgentProcessTable(surfaces: surfaces).found(rule)
        }
    }
}
