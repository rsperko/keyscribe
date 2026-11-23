import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct DiscoveryReportCLITests {
    private func fixture() -> (agentsDir: URL, folder: URL, connector: ConnectorCLITests.Connector) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-discovery-cli-\(UUID().uuidString)", isDirectory: true)
        let agentsDir = root.appendingPathComponent("support/agents", isDirectory: true)
        let folder = root.appendingPathComponent("home/.folder", isDirectory: true)
        try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (agentsDir, folder, ConnectorCLITests.Connector(defaultFolder: root.appendingPathComponent("home/.default", isDirectory: true)))
    }

    @Test func theReportNamesTheAgentAndTheFolderItLookedInAfterPreparingDiscovery() async {
        let (agentsDir, folder, connector) = fixture()
        var prepared: [String] = []
        let outcome = await DiscoveryReportCLI.run(
            agent: "folder", folder: folder, connectors: [connector], agentsDir: agentsDir,
            prepare: { prepared.append($0) })
        #expect(outcome.code == 0)
        #expect(prepared == ["folder"])
        let report = outcome.lines.joined(separator: "\n")
        #expect(report.contains("how it finds Folder Agent"))
        #expect(report.contains(ConnectorFolders.canonical(folder).path))
    }

    @Test func theReportChangesNothing() async {
        let (agentsDir, folder, connector) = fixture()
        _ = await DiscoveryReportCLI.run(agent: "folder", folder: folder, connectors: [connector], agentsDir: agentsDir, prepare: { _ in })
        #expect(!connector.installed)
        #expect(ConnectorSetupRegistry(directory: agentsDir).setups?.enrolled(agent: "folder").isEmpty ?? true)
    }

    @Test func anUnknownAgentIsRefusedAndTheKnownOnesAreNamed() async {
        let (agentsDir, folder, connector) = fixture()
        let outcome = await DiscoveryReportCLI.run(agent: "nope", folder: folder, connectors: [connector], agentsDir: agentsDir, prepare: { _ in })
        #expect(outcome.code == 2)
        #expect(outcome.lines.contains { $0.contains("folder") })
    }

    @Test func withNoFolderAskedForTheReportIsAboutTheFolderTheLoginShellNamesAndSaysWhy() async {
        let (agentsDir, folder, connector) = fixture()
        connector.variable = "FOLDER_HOME"
        let outcome = await DiscoveryReportCLI.run(
            agent: "folder", folder: nil, connectors: [connector], agentsDir: agentsDir, prepare: { _ in },
            declared: { $0 == "FOLDER_HOME" ? folder.path : nil })
        let report = outcome.lines.joined(separator: "\n")
        let path = ConnectorFolders.canonical(folder).path
        #expect(report.contains("Configuration folder: \(path)"))
        #expect(report.contains("\(path) (FOLDER_HOME in your login shell)"))
        #expect(report.contains("\(ConnectorFolders.canonical(connector.defaultFolder).path) (default)"))
    }
}
