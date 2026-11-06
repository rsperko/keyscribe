import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct ClaudeConnectorInstallerTests {
    final class Runner: @unchecked Sendable {
        var calls: [[String]] = []
        var status: Int32 = 0
        func run(_ argv: [String]) -> (Int32, String) {
            calls.append(argv)
            return (status, "")
        }
    }

    private func setup(plugin: String = "keyscribe-dev") -> (ClaudeConnectorInstaller, Runner, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agents-\(UUID().uuidString)")
        let runner = Runner()
        let installer = ClaudeConnectorInstaller(
            agentsDir: dir, pluginName: plugin, claude: "/bin/claude-test",
            socketPath: dir.appendingPathComponent("bridge.sock").path,
            tokenPath: dir.appendingPathComponent("token").path,
            run: runner.run)
        return (installer, runner, dir)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    @Test func installWritesAMarketplaceWithTheConnectorPlugin() throws {
        let (installer, _, dir) = try (setup())
        try installer.install()
        let market = dir.appendingPathComponent("claude-connector")
        let manifest = try json(market.appendingPathComponent(".claude-plugin/marketplace.json"))
        #expect(manifest["name"] as? String == "keyscribe-dev-local")
        let plugins = manifest["plugins"] as? [[String: Any]]
        #expect(plugins?.first?["name"] as? String == "keyscribe-dev")
        #expect(plugins?.first?["source"] as? String == "./keyscribe-dev")

        let plugin = market.appendingPathComponent("keyscribe-dev")
        #expect(try json(plugin.appendingPathComponent(".claude-plugin/plugin.json"))["name"] as? String == "keyscribe-dev")
        #expect(try json(plugin.appendingPathComponent("hooks/hooks.json"))["modules"] as? [String] == ["./register.js"])
        #expect(FileManager.default.fileExists(atPath: plugin.appendingPathComponent("hooks/register.js").path))
        let config = try json(plugin.appendingPathComponent("keyscribe.json"))
        #expect(config["socketPath"] as? String == dir.appendingPathComponent("bridge.sock").path)
        #expect(config["tokenPath"] as? String == dir.appendingPathComponent("token").path)
    }

    @Test func installRegistersTheMarketplaceAndInstallsAtUserScope() throws {
        let (installer, runner, dir) = setup()
        try installer.install()
        #expect(runner.calls == [
            ["/bin/claude-test", "plugin", "marketplace", "add", dir.appendingPathComponent("claude-connector").path],
            ["/bin/claude-test", "plugin", "install", "keyscribe-dev@keyscribe-dev-local", "--scope", "user"],
        ])
    }

    @Test func updateRewritesTheFilesAndRefreshesTheInstall() throws {
        let (installer, runner, _) = setup()
        try installer.install()
        runner.calls = []
        try installer.update()
        #expect(runner.calls == [
            ["/bin/claude-test", "plugin", "marketplace", "update", "keyscribe-dev-local"],
            ["/bin/claude-test", "plugin", "update", "keyscribe-dev@keyscribe-dev-local"],
        ])
    }

    @Test func uninstallRemovesOnlyWhatItOwns() throws {
        let (installer, runner, dir) = setup()
        try installer.install()
        let unrelated = dir.appendingPathComponent("bridge.sock")
        try Data().write(to: unrelated)
        runner.calls = []
        try installer.uninstall()
        #expect(runner.calls == [
            ["/bin/claude-test", "plugin", "uninstall", "keyscribe-dev@keyscribe-dev-local"],
            ["/bin/claude-test", "plugin", "marketplace", "remove", "keyscribe-dev-local"],
        ])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("claude-connector").path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func aFailingClaudeCommandStopsTheInstall() throws {
        let (installer, runner, _) = setup()
        runner.status = 1
        #expect(throws: ClaudeConnectorInstaller.InstallError.self) { try installer.install() }
        #expect(runner.calls.count == 1)
    }

    @Test func productionAndDevUseDifferentPluginNames() {
        #expect(ClaudeConnectorInstaller.pluginName(for: .production) == "keyscribe")
        #expect(ClaudeConnectorInstaller.pluginName(for: .dev) == "keyscribe-dev")
    }

    @Test func theModNeverHardcodesAVariantOrPath() {
        let source = ClaudeConnectorFiles.registerJS
        #expect(!source.contains("/Users/"))
        #expect(!source.contains("KeyScribeDev"))
        #expect(source.contains("keyscribe.json"))
    }
}

struct AgentBridgeTokenTests {
    @Test func aTokenIsCreatedOwnerOnlyAndThenReused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-token-\(UUID().uuidString)")
        let first = try AgentBridgeToken.loadOrCreate(in: dir)
        let second = try AgentBridgeToken.loadOrCreate(in: dir)
        #expect(first == second)
        #expect(first.count >= 32)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("token").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
