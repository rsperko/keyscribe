import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct ConnectorCLITests {
    final class Connector: AgentConnector {
        let kind = AgentKind(id: "folder", displayName: "Folder Agent", connectorName: "Folder Agent extension")
        let copy = BBPluginConnector(agentsDir: URL(fileURLWithPath: "/tmp"), pluginName: "p").copy
        let isBundled = true
        let bundledVersion: String? = "1"
        let defaultFolder: URL
        var installed = false
        var installFailure: String?
        private(set) var installedInto: [String] = []

        init(defaultFolder: URL) { self.defaultFolder = defaultFolder }

        func hasFiles(in target: ConnectorTarget) -> Bool { installed }
        func manualUninstall(for target: ConnectorTarget) -> [String] { [] }
        func recognizes(folder: URL) -> Bool { true }
        func findTool(in folder: URL, chosen: String?) -> ToolSearch.Result? { nil }
        func check(tool: String, target: ConnectorTarget) async -> AgentConnectorModel.State {
            if target.removing { return installed ? .removalUnfinished(nil) : .status(.notInstalled) }
            return installed ? .status(.ready) : .status(.notInstalled)
        }
        func install(tool: String, target: ConnectorTarget) async throws {
            if let installFailure { throw AgentConnectorError(message: installFailure) }
            installedInto.append(target.folder.path)
            installed = true
        }
        func update(tool: String, target: ConnectorTarget) async throws { installed = true }
        func uninstall(tool: String, target: ConnectorTarget) async throws { installed = false }
        func uninstallWithoutTool(target: ConnectorTarget) async throws { installed = false }
    }

    @MainActor private struct Fixture {
        let agentsDir: URL
        let folder: URL
        let connector: Connector

        init() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-connector-cli-\(UUID().uuidString)", isDirectory: true)
            agentsDir = root.appendingPathComponent("support/agents", isDirectory: true)
            folder = root.appendingPathComponent("home/.folder", isDirectory: true)
            try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            connector = Connector(defaultFolder: root.appendingPathComponent("home/.default", isDirectory: true))
        }

        func run(_ action: ConnectorCLI.Action, agent: String = "folder", bridgeAnswers: Bool = false) async -> ConnectorCLI.Outcome {
            await ConnectorCLI.run(
                action: action, agent: agent, folder: folder, tool: nil, connectors: [connector], agentsDir: agentsDir,
                bridgeAnswers: { _ in bridgeAnswers })
        }

        var enrolled: [String] {
            ConnectorSetupRegistry(directory: agentsDir).setups?.enrolled(agent: "folder").map(\.folder) ?? []
        }
    }

    @Test func installEnrollsTheFolderInstallsIntoItAndSaysItIsReady() async {
        let fixture = Fixture()
        let outcome = await fixture.run(.install)
        #expect(outcome.code == 0)
        #expect(fixture.connector.installedInto == [ConnectorFolders.canonical(fixture.folder).path])
        #expect(fixture.enrolled == [ConnectorFolders.canonical(fixture.folder).path])
        #expect(outcome.lines.contains { $0.contains("ready") })
    }

    @Test func uninstallRemovesTheConnectorAndTheEnrollment() async {
        let fixture = Fixture()
        _ = await fixture.run(.install)
        let outcome = await fixture.run(.uninstall)
        #expect(outcome.code == 0)
        #expect(!fixture.connector.installed)
        #expect(fixture.enrolled.isEmpty)
    }

    @Test func statusReportsWithoutChangingAnything() async {
        let fixture = Fixture()
        let outcome = await fixture.run(.status)
        #expect(outcome.code == 0)
        #expect(outcome.lines.contains { $0.contains("notInstalled") })
        #expect(!fixture.connector.installed)
        #expect(fixture.enrolled.isEmpty)
    }

    @Test func aFailedInstallExitsNonZeroWithTheConnectorsReason() async {
        let fixture = Fixture()
        fixture.connector.installFailure = "the folder is read-only"
        let outcome = await fixture.run(.install)
        #expect(outcome.code == 1)
        #expect(outcome.lines.contains { $0.contains("the folder is read-only") })
    }

    @Test func anUnknownAgentIsRefusedAndTheKnownOnesAreNamed() async {
        let fixture = Fixture()
        let outcome = await fixture.run(.install, agent: "nope")
        #expect(outcome.code == 2)
        #expect(outcome.lines.contains { $0.contains("folder") })
        #expect(!fixture.connector.installed)
    }

    @Test func aChangeIsRefusedWhileThatInstancesBridgeAnswersButStatusStillReads() async {
        let fixture = Fixture()
        let install = await fixture.run(.install, bridgeAnswers: true)
        #expect(install.code == 1)
        #expect(!fixture.connector.installed)
        #expect(fixture.enrolled.isEmpty)
        #expect(await fixture.run(.status, bridgeAnswers: true).code == 0)
    }

    @Test func theBridgeProbeAnswersOnlyForAListeningSocket() throws {
        let dir = URL(fileURLWithPath: "/tmp/ks-probe-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let socket = dir.appendingPathComponent("bridge.sock")
        #expect(!ConnectorCLI.bridgeAnswers(socket))
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socket.path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)
        #expect(ConnectorCLI.bridgeAnswers(socket))
    }
}
