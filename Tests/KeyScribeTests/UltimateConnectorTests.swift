import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct UltimateConnectorTests {
    static let sources = [
        "server.ts": "server", "keyscribe.ts": "core", "web.solid.tsx": "const extension = 'keyscribe'\nrest",
        "web.tsx": "const extension = 'keyscribe'\nreact", "README.md": "readme",
    ]

    private func scratch() -> (home: URL, agents: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-ultimate-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".ultimate/projects"), withIntermediateDirectories: true)
        return (home, root.appendingPathComponent("agents", isDirectory: true))
    }

    private func connector(
        _ home: URL, _ agents: URL, id: String = "keyscribe-dev", sources: [String: String]? = Self.sources,
        silentProject: @escaping @Sendable (URL) async -> String? = { _ in nil }
    ) -> UltimateConnector {
        UltimateConnector(agentsDir: agents, pluginName: id, home: home, sources: sources, silentProject: silentProject)
    }

    private func target(_ home: URL, installation: String? = "inst-u", removing: Bool = false) -> ConnectorTarget {
        ConnectorTarget(folder: home.appendingPathComponent(".ultimate", isDirectory: true), isDefault: true, installation: installation, removing: removing)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func installingWritesTheExtensionUnderThisAppsIdInTheUserExtensionsFolder() async throws {
        let (home, agents) = scratch()
        let connector = connector(home, agents)
        try await connector.install(tool: "/bin/ultimate", target: target(home))
        let folder = home.appendingPathComponent(".ultimate/extensions/keyscribe-dev")
        #expect(read(folder.appendingPathComponent("server.ts")) == "server")
        #expect(read(folder.appendingPathComponent("keyscribe.ts")) == "core")
        #expect(read(folder.appendingPathComponent("README.md")) == "readme")
        #expect(read(folder.appendingPathComponent("web.solid.tsx")) == "const extension = 'keyscribe-dev'\nrest")
        #expect(read(folder.appendingPathComponent("web.tsx")) == "const extension = 'keyscribe-dev'\nreact")
        let config = try #require(FileManager.default.contents(atPath: folder.appendingPathComponent("keyscribe.json").path))
        let settings = try #require(try JSONSerialization.jsonObject(with: config) as? [String: Any])
        #expect(settings["installation"] as? String == "inst-u")
        #expect(settings["plugin"] as? String == "keyscribe-dev")
        #expect(settings["socketPath"] as? String == agents.appendingPathComponent("bridge.sock").path)
        #expect(settings["setup"] as? String == ConnectorFolders.canonical(home.appendingPathComponent(".ultimate")).path)
    }

    @Test func theServerFileIsWrittenLastSoUltimateNeverLoadsItWithoutItsSettings() {
        #expect(UltimateConnectorFiles.writeOrder.first == UltimateConnectorFiles.configName)
        #expect(UltimateConnectorFiles.writeOrder.last == "server.ts")
        #expect(Set(UltimateConnectorFiles.writeOrder) == Set(UltimateConnectorFiles.names + [UltimateConnectorFiles.configName]))
    }

    @Test func aCurrentInstallIsReadyAndAChangedFileIsOutdated() async throws {
        let (home, agents) = scratch()
        let connector = connector(home, agents)
        try await connector.install(tool: "/bin/ultimate", target: target(home))
        #expect(await connector.check(tool: "/bin/ultimate", target: target(home)) == .status(.ready))
        let core = home.appendingPathComponent(".ultimate/extensions/keyscribe-dev/keyscribe.ts")
        try Data("older".utf8).write(to: core)
        guard case .status(.outdated) = await connector.check(tool: "/bin/ultimate", target: target(home)) else {
            Issue.record("a changed file must read as outdated")
            return
        }
    }

    @Test func installingOverAnOlderVersionLeavesOnlyTheFilesThisVersionShips() async throws {
        let (home, agents) = scratch()
        let connector = connector(home, agents)
        let folder = home.appendingPathComponent(".ultimate/extensions/keyscribe-dev")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("old"), withIntermediateDirectories: true)
        try Data("retired".utf8).write(to: folder.appendingPathComponent("retired.ts"))
        try Data("nested".utf8).write(to: folder.appendingPathComponent("old/kept.ts"))
        try await connector.install(tool: "/bin/ultimate", target: target(home))
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(Set(left) == Set(UltimateConnectorFiles.writeOrder))
        #expect(await connector.check(tool: "/bin/ultimate", target: target(home)) == .status(.ready))
    }

    @Test func theAppCarriesTheExtensionSourcesAndNamesThePageForThisApp() throws {
        let sources = try #require(UltimateConnectorFiles.sources)
        #expect(Set(sources.keys) == Set(UltimateConnectorFiles.names))
        let written = UltimateConnectorFiles.written(sources, id: "keyscribe-dev")
        for name in ["web.solid.tsx", "web.tsx"] {
            let page = try #require(written[name])
            #expect(page.contains("const extension = 'keyscribe-dev'"))
            #expect(!page.contains("const extension = 'keyscribe'\n"))
        }
    }

    @Test func currentFilesInAProjectWhoseExtensionIsNotAnsweringAreNotWorkingNotReady() async throws {
        let (home, agents) = scratch()
        let asked = Asked()
        let silent = connector(home, agents, silentProject: { setup in
            await asked.add(setup.path)
            return "app"
        })
        try await silent.install(tool: "/bin/ultimate", target: target(home))
        guard case .broken(let message) = await silent.check(tool: "/bin/ultimate", target: target(home)) else {
            Issue.record("a running project whose extension does not answer must not read as ready")
            return
        }
        #expect(message.contains("app"))
        #expect(message.contains("status line"))
        #expect(!message.contains("0.1"))
        #expect(await asked.paths == [home.appendingPathComponent(".ultimate").path])
        try Data("older".utf8).write(to: home.appendingPathComponent(".ultimate/extensions/keyscribe-dev/keyscribe.ts"))
        guard case .status(.outdated) = await silent.check(tool: "/bin/ultimate", target: target(home)) else {
            Issue.record("outdated files are updated before the running projects are asked")
            return
        }
    }

    actor Asked {
        var paths: [String] = []
        func add(_ path: String) { paths.append(path) }
    }

    @Test func anotherInstallationsSettingsAreOutdatedNotReady() async throws {
        let (home, agents) = scratch()
        let connector = connector(home, agents)
        try await connector.install(tool: "/bin/ultimate", target: target(home, installation: "old"))
        guard case .status(.outdated) = await connector.check(tool: "/bin/ultimate", target: target(home, installation: "new")) else {
            Issue.record("settings naming another installation must be rewritten")
            return
        }
    }

    @Test func withoutItsFilesTheExtensionIsNotInstalled() async {
        let (home, agents) = scratch()
        #expect(await connector(home, agents).check(tool: "/bin/ultimate", target: target(home)) == .status(.notInstalled))
    }

    @Test func turnedOffInUltimatesSettingsIsDisabled() async throws {
        let (home, agents) = scratch()
        let connector = connector(home, agents)
        try await connector.install(tool: "/bin/ultimate", target: target(home))
        try Data(#"{"extensions":{"disable":["keyscribe-dev"]}}"#.utf8).write(to: home.appendingPathComponent(".ultimate/settings.json"))
        #expect(await connector.check(tool: "/bin/ultimate", target: target(home)) == .status(.disabled))
    }

    @Test func unreadableUltimateSettingsAreUnconfirmedNeverReady() async throws {
        let (home, agents) = scratch()
        let connector = connector(home, agents)
        try await connector.install(tool: "/bin/ultimate", target: target(home))
        try Data("{ not json".utf8).write(to: home.appendingPathComponent(".ultimate/settings.json"))
        guard case .unconfirmed = await connector.check(tool: "/bin/ultimate", target: target(home)) else {
            Issue.record("settings that cannot be read must not read as ready")
            return
        }
    }

    @Test func uninstallingRemovesOnlyTheExtensionFolder() async throws {
        let (home, agents) = scratch()
        let connector = connector(home, agents)
        let setup = home.appendingPathComponent(".ultimate")
        try Data("{}".utf8).write(to: setup.appendingPathComponent("settings.json"))
        try FileManager.default.createDirectory(at: setup.appendingPathComponent("extensions/mine"), withIntermediateDirectories: true)
        try await connector.install(tool: "/bin/ultimate", target: target(home))
        try await connector.uninstallWithoutTool(target: target(home, removing: true))
        #expect(!FileManager.default.fileExists(atPath: setup.appendingPathComponent("extensions/keyscribe-dev").path))
        #expect(FileManager.default.fileExists(atPath: setup.appendingPathComponent("extensions/mine").path))
        #expect(FileManager.default.fileExists(atPath: setup.appendingPathComponent("settings.json").path))
        #expect(await connector.check(tool: "/bin/ultimate", target: target(home, removing: true)) == .status(.notInstalled))
    }

    @Test func leftoverFilesDuringRemovalAreUnfinished() async throws {
        let (home, agents) = scratch()
        let connector = connector(home, agents)
        try await connector.install(tool: "/bin/ultimate", target: target(home))
        #expect(await connector.check(tool: "/bin/ultimate", target: target(home, removing: true)) == .removalUnfinished(nil))
    }

    @Test func onlyAnUltimateUserFolderIsRecognized() throws {
        let (home, agents) = scratch()
        let connector = connector(home, agents)
        #expect(connector.recognizes(folder: home.appendingPathComponent(".ultimate")))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("other/projects"), withIntermediateDirectories: true)
        #expect(!connector.recognizes(folder: home.appendingPathComponent("other")))
    }

    @Test func aMissingBundleIsUnavailable() async {
        let (home, agents) = scratch()
        #expect(await connector(home, agents, sources: nil).check(tool: "/bin/ultimate", target: target(home)) == .unavailable)
    }
}
