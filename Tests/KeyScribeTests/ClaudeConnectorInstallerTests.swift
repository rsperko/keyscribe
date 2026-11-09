import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct ClaudeConnectorInstallerTests {
    final class Runner: @unchecked Sendable {
        var calls: [[String]] = []
        var configDirs: [String?] = []
        var status: Int32 = 0
        var plugins: Set<String> = []
        var marketplaces: Set<String> = []
        var failing: [String: (Int32, String)] = [:]

        func run(_ argv: [String], _ environment: [String: String]) -> (Int32, String) {
            calls.append(argv)
            configDirs.append(environment["CLAUDE_CONFIG_DIR"])
            if status != 0 { return (status, "") }
            let args = Array(argv.dropFirst(2))
            let key = args.first == "marketplace" || args.first == "list" ? args.prefix(2).joined(separator: " ") : args.first ?? ""
            if let failure = failing[key] { return failure }
            switch key {
            case "marketplace add": marketplaces.insert("keyscribe-dev-local")
            case "install": plugins.insert(args[1])
            case "uninstall":
                guard plugins.remove(args[1]) != nil else { return (1, "Plugin \"\(args[1])\" not found in installed plugins") }
            case "marketplace remove":
                guard marketplaces.remove(args[2]) != nil else { return (1, "Marketplace '\(args[2])' not found") }
                plugins = plugins.filter { !$0.hasSuffix("@\(args[2])") }
            case "list --json":
                return (0, "[" + plugins.sorted().map { #"{"id":"\#($0)","scope":"user","enabled":true}"# }.joined(separator: ",") + "]")
            case "marketplace list":
                return (0, "[" + marketplaces.sorted().map { #"{"name":"\#($0)","source":"directory"}"# }.joined(separator: ",") + "]")
            default: break
            }
            return (0, "")
        }
    }

    static let pluginId = "keyscribe-dev@keyscribe-dev-local"
    static let setupFolder = URL(fileURLWithPath: "/Users/me/.claude-work", isDirectory: true)

    private func setup(plugin: String = "keyscribe-dev", isDefault: Bool = false) -> (ClaudeConnectorInstaller, Runner, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-agents-\(UUID().uuidString)")
        let runner = Runner()
        let installer = ClaudeConnectorInstaller(
            agentsDir: dir, setupFolder: Self.setupFolder, isDefaultSetup: isDefault, pluginName: plugin, claude: "/bin/claude-test",
            socketPath: dir.appendingPathComponent("bridge.sock").path,
            tokenPath: dir.appendingPathComponent("token").path,
            readyPath: dir.appendingPathComponent("ready.json").path,
            script: Self.script, run: runner.run, baseEnvironment: ["CLAUDE_CONFIG_DIR": "/inherited", "PATH": "/usr/bin"])
        return (installer, runner, dir)
    }

    private func market(_ dir: URL) -> URL { ClaudeConnectorInstaller.marketplaceDir(in: dir, setupFolder: Self.setupFolder) }

    static let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/KeyScribe/Resources/ClaudeConnector/register.js")
    static let script = ClaudeConnectorFiles.registerJS ?? ""

    private func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    @Test func installWritesAMarketplaceOfThisSetupsOwnWithTheConnectorPlugin() throws {
        let (installer, _, dir) = setup()
        try installer.install(installation: "id-1")
        let market = market(dir)
        #expect(market.deletingLastPathComponent().lastPathComponent == "claude-connector")
        let manifest = try json(market.appendingPathComponent(".claude-plugin/marketplace.json"))
        #expect(manifest["name"] as? String == "keyscribe-dev-local")
        let plugins = manifest["plugins"] as? [[String: Any]]
        #expect(plugins?.first?["name"] as? String == "keyscribe-dev")
        #expect(plugins?.first?["source"] as? String == "./keyscribe-dev")

        let plugin = market.appendingPathComponent("keyscribe-dev")
        #expect(try json(plugin.appendingPathComponent(".claude-plugin/plugin.json"))["name"] as? String == "keyscribe-dev")
        #expect(try json(plugin.appendingPathComponent("hooks/hooks.json"))["modules"] as? [String] == ["./register.js"])
        let code = try String(contentsOf: plugin.appendingPathComponent("hooks/register.js"), encoding: .utf8)
        #expect(code.contains("let loadedFrom = \"id-1\""))
        let config = try json(plugin.appendingPathComponent("keyscribe.json"))
        #expect(config["socketPath"] as? String == dir.appendingPathComponent("bridge.sock").path)
        #expect(config["tokenPath"] as? String == dir.appendingPathComponent("token").path)
        #expect(config["readyPath"] as? String == dir.appendingPathComponent("ready.json").path)
        #expect(config["installation"] as? String == "id-1")
        #expect(config["version"] as? String == ClaudeConnectorFiles.version(for: Self.script))
        #expect(code.contains("const appLabel = \"\(Branding.appName)\""))
    }

    @Test func differentSetupsGetDifferentMarketplaceFolders() {
        let dir = URL(fileURLWithPath: "/agents")
        #expect(ClaudeConnectorInstaller.marketplaceDir(in: dir, setupFolder: URL(fileURLWithPath: "/a"))
            != ClaudeConnectorInstaller.marketplaceDir(in: dir, setupFolder: URL(fileURLWithPath: "/b")))
    }

    @Test func installRegistersTheMarketplaceAndInstallsAtUserScopeInTheChosenSetupOnly() throws {
        let (installer, runner, dir) = setup()
        try installer.install(installation: "id-1")
        #expect(runner.calls == [
            ["/bin/claude-test", "plugin", "marketplace", "add", market(dir).path],
            ["/bin/claude-test", "plugin", "install", "keyscribe-dev@keyscribe-dev-local", "--scope", "user"],
        ])
        #expect(runner.configDirs == [Self.setupFolder.path, Self.setupFolder.path])
    }

    @Test func theDefaultSetupRunsWithoutAnInheritedConfigFolder() throws {
        let (installer, runner, _) = setup(isDefault: true)
        try installer.install(installation: "id-1")
        #expect(runner.configDirs == [nil, nil])
    }

    @Test func updateRewritesTheFilesAndRefreshesTheInstall() throws {
        let (installer, runner, _) = setup()
        try installer.install(installation: "id-1")
        runner.calls = []
        try installer.update(installation: "id-1")
        #expect(runner.calls == [
            ["/bin/claude-test", "plugin", "marketplace", "update", "keyscribe-dev-local"],
            ["/bin/claude-test", "plugin", "update", "keyscribe-dev@keyscribe-dev-local", "--scope", "user"],
        ])
    }

    @Test func uninstallRemovesOnlyWhatItOwns() throws {
        let (installer, runner, dir) = setup()
        try installer.install(installation: "id-1")
        let unrelated = dir.appendingPathComponent("bridge.sock")
        try Data().write(to: unrelated)
        runner.calls = []
        try installer.uninstall()
        #expect(runner.calls == [
            ["/bin/claude-test", "plugin", "uninstall", "keyscribe-dev@keyscribe-dev-local", "--scope", "user"],
            ["/bin/claude-test", "plugin", "marketplace", "remove", "keyscribe-dev-local"],
            ["/bin/claude-test", "plugin", "list", "--json"],
            ["/bin/claude-test", "plugin", "marketplace", "list", "--json"],
        ])
        #expect(!FileManager.default.fileExists(atPath: market(dir).path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func uninstallingWhatIsAlreadyGoneSucceedsAndRemovesTheFiles() throws {
        let (installer, runner, dir) = setup()
        try installer.install(installation: "id-1")
        runner.plugins = []
        runner.marketplaces = []
        try installer.uninstall()
        #expect(!FileManager.default.fileExists(atPath: market(dir).path))
        try installer.uninstall()
    }

    @Test func aFailedPluginUninstallStillRemovesTheMarketplaceWhichTakesThePluginWithIt() throws {
        let (installer, runner, dir) = setup()
        try installer.install(installation: "id-1")
        runner.failing["uninstall"] = (1, "locked")
        try installer.uninstall()
        #expect(runner.calls.contains { $0.contains("remove") })
        #expect(runner.plugins.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: market(dir).path))
    }

    @Test func whileClaudeCodeStillListsTheConnectorUninstallFailsWithWhatClaudeSaidAndKeepsTheFiles() throws {
        let (installer, runner, dir) = setup()
        try installer.install(installation: "id-1")
        runner.failing["uninstall"] = (1, "locked")
        runner.failing["marketplace remove"] = (1, "busy")
        #expect(throws: ClaudeConnectorInstaller.InstallError(
            command: ["/bin/claude-test", "plugin", "uninstall", Self.pluginId, "--scope", "user"], status: 1, output: "locked"))
        { try installer.uninstall() }
        #expect(FileManager.default.fileExists(atPath: market(dir).path))

        runner.failing = [:]
        try installer.uninstall()
        #expect(runner.plugins.isEmpty && runner.marketplaces.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: market(dir).path))
    }

    @Test func aMarketplaceLeftBehindWhenEveryCommandSucceededIsReported() throws {
        let (installer, runner, dir) = setup()
        try installer.install(installation: "id-1")
        runner.failing["marketplace remove"] = (0, "")
        #expect(throws: ClaudeConnectorInstaller.InstallError.self) { try installer.uninstall() }
        #expect(FileManager.default.fileExists(atPath: market(dir).path))
    }

    @Test func uninstallIsNotConfirmedWhenClaudeCodeCannotListWhatIsInstalled() throws {
        let (installer, runner, dir) = setup()
        try installer.install(installation: "id-1")
        runner.failing["list --json"] = (1, "cannot read settings")
        #expect(throws: ClaudeConnectorInstaller.InstallError(
            command: ["/bin/claude-test", "plugin", "list", "--json"], status: 1, output: "cannot read settings"))
        { try installer.uninstall() }
        #expect(FileManager.default.fileExists(atPath: market(dir).path))

        runner.failing = [:]
        runner.failing["marketplace list"] = (0, "not json")
        #expect(throws: ClaudeConnectorInstaller.InstallError.self) { try installer.uninstall() }
        #expect(FileManager.default.fileExists(atPath: market(dir).path))
    }

    @Test func theCommandsToUninstallByHandNameEachVariantsOwnConnectorAndItsSetup() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(ClaudeConnectorInstaller.manualUninstall(
            pluginName: ClaudeConnectorInstaller.pluginName(for: .production), setupFolder: home.appendingPathComponent(".claude"), isDefault: true) == [
            "env -u CLAUDE_CONFIG_DIR claude plugin uninstall keyscribe@keyscribe-local --scope user",
            "env -u CLAUDE_CONFIG_DIR claude plugin marketplace remove keyscribe-local",
        ])
        #expect(ClaudeConnectorInstaller.manualUninstall(
            pluginName: "keyscribe-dev", setupFolder: home.appendingPathComponent("claude work"), isDefault: false).first
            == "CLAUDE_CONFIG_DIR=~/'claude work' claude plugin uninstall keyscribe-dev@keyscribe-dev-local --scope user")
        #expect(ClaudeConnectorInstaller.manualUninstall(
            pluginName: "keyscribe-dev", setupFolder: URL(fileURLWithPath: "/Volumes/Work Disk/.claude"), isDefault: false).first
            == "CLAUDE_CONFIG_DIR='/Volumes/Work Disk/.claude' claude plugin uninstall keyscribe-dev@keyscribe-dev-local --scope user")
    }

    @Test func aFailingClaudeCommandStopsTheInstall() throws {
        let (installer, runner, _) = setup()
        runner.status = 1
        #expect(throws: ClaudeConnectorInstaller.InstallError.self) { try installer.install(installation: "id-1") }
        #expect(runner.calls.count == 1)
    }

    @Test func productionAndDevUseDifferentPluginNames() {
        #expect(ClaudeConnectorInstaller.pluginName(for: .production) == "keyscribe")
        #expect(ClaudeConnectorInstaller.pluginName(for: .dev) == "keyscribe-dev")
    }

    @Test func thePackagedConnectorIsTheCheckedInSourceByteForByte() throws {
        let bundled = try #require(ClaudeConnectorFiles.registerJS)
        #expect(Data(bundled.utf8) == (try Data(contentsOf: Self.source)))
    }

    @Test func installWritesThePackagedConnectorChangingOnlyTheInstallationItCameFromAndTheAppsName() throws {
        let (installer, _, dir) = setup()
        try installer.install(installation: "id-1")
        let installed = try String(contentsOf: market(dir).appendingPathComponent("keyscribe-dev/hooks/register.js"), encoding: .utf8)
        let restored = installed.replacingOccurrences(of: "let loadedFrom = \"id-1\"", with: "let loadedFrom = null")
            .replacingOccurrences(of: "const appLabel = \"\(Branding.appName)\"", with: "const appLabel = null")
        #expect(restored != installed)
        #expect(Data(restored.utf8) == (try Data(contentsOf: Self.source)))
    }

    @Test func aMissingResourceBundleFindsNoConnector() {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("ks-missing-\(UUID().uuidString)/X.bundle")
        #expect(ClaudeConnectorFiles.script(searching: [nowhere]) == nil)
    }

    @Test func aBundleWithoutTheConnectorFindsNone() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("ks-empty-\(UUID().uuidString)/X.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(ClaudeConnectorFiles.script(searching: [bundle]) == nil)
    }

    @Test func theFirstBundleHoldingTheConnectorIsRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-found-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("X.bundle/Contents/Resources")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("export function register(on) {}\n".utf8).write(to: bundle.appendingPathComponent("register.js"))
        let found = ClaudeConnectorFiles.script(searching: [root.appendingPathComponent("missing.bundle"), root.appendingPathComponent("X.bundle")])
        #expect(found == "export function register(on) {}\n")
    }

    @Test func theModNeverHardcodesAVariantOrPath() {
        let source = Self.script
        #expect(!source.contains("/Users/"))
        #expect(!source.contains("KeyScribeDev"))
        #expect(source.contains("keyscribe.json"))
    }

    @Test func theModReadsOnlyWhereItsTerminalShowsItNeverAnAccessToken() throws {
        let source = Self.script
        let reads = try Regex(#"\$\.env\.get\("([A-Z_]+)"\)"#)
        #expect(source.matches(of: reads).compactMap { $0.output[1].substring.map(String.init) } == ["ZELLIJ_PANE_ID", "CMUX_SURFACE_ID"])
        #expect(source.contains("const features = ['focus', 'label', 'readiness', 'notify']"))
    }

    @Test func thePluginVersionNamesTheConnectorCodeItCarries() throws {
        let (installer, _, dir) = setup()
        try installer.install(installation: "id-1")
        let manifest = try json(market(dir).appendingPathComponent("keyscribe-dev/.claude-plugin/plugin.json"))
        #expect(manifest["version"] as? String == ClaudeConnectorFiles.version)
        #expect(ClaudeConnectorFiles.version == ClaudeConnectorFiles.version(for: Self.script))
        #expect(ClaudeConnectorFiles.version(for: Self.script + " ") != ClaudeConnectorFiles.version)
        #expect(ClaudeConnectorFiles.version?.hasPrefix("0.1.0-") == true)
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
