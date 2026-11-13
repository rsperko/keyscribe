import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct PiCLITests {
    @Test func theVersionIsReadFromWhateverPiPrints() {
        #expect(PiCLI.version(in: "1.5.0\n") == [1, 5, 0])
        #expect(PiCLI.version(in: "pi v1.4.0") == [1, 4, 0])
        #expect(PiCLI.version(in: "1.6.0-beta.2") == [1, 6, 0])
        #expect(PiCLI.version(in: "command not found") == nil)
        #expect(PiCLI.version(in: "") == nil)
        #expect(PiCLI.version(in: "(node:123) DeprecationWarning: punycode since v22.1.0\n1.5.0\n") == [1, 5, 0])
        #expect(PiCLI.version(in: "(node:123) DeprecationWarning: punycode since v22.1.0\n") == nil)
        #expect(PiCLI.version(in: "1.4\n") == [1, 4, 0])
        #expect(PiCLI.isSupported(PiCLI.version(in: "1.4\n") ?? []))
    }

    @Test func versionsBelowTheFloorAreNotSupported() {
        #expect(PiCLI.isSupported([1, 4, 0]))
        #expect(PiCLI.isSupported([1, 5, 0]))
        #expect(PiCLI.isSupported([2, 0]))
        #expect(!PiCLI.isSupported([1, 3, 9]))
        #expect(!PiCLI.isSupported([0, 80, 3]))
        #expect(PiCLI.describe([1, 4, 0]) == "1.4.0")
    }

    @Test func piIsFoundOnThePathFirstThenUnderTheNewestNodeVersionManagerInstall() {
        let home = URL(fileURLWithPath: "/Users/me")
        let listing: (URL) -> [String] = { $0.path.hasSuffix(".nvm/versions/node") ? ["v22.1.0", "v24.21.0", "v9.0.0"] : [] }
        let onPath = PiCLI.locate(environment: ["PATH": "/custom/bin"], home: home, isExecutable: { $0 == "/custom/bin/pi" || $0.hasPrefix("/Users/me/.nvm") }, listing: listing)
        #expect(onPath == "/custom/bin/pi")
        let newest = PiCLI.locate(environment: ["PATH": "/usr/bin"], home: home, isExecutable: { $0.hasPrefix("/Users/me/.nvm") }, listing: listing)
        #expect(newest == "/Users/me/.nvm/versions/node/v24.21.0/bin/pi")
        let volta = PiCLI.locate(environment: [:], home: home, isExecutable: { $0 == "/Users/me/.volta/bin/pi" }, listing: listing)
        #expect(volta == "/Users/me/.volta/bin/pi")
        #expect(PiCLI.locate(environment: [:], home: home, isExecutable: { _ in false }, listing: listing) == nil)
    }

    @Test func runningPiPutsItsOwnFolderFirstOnThePathSoItsNodeIsFound() {
        let (status, output) = PiCLI.run(["/bin/sh", "-c", "echo $PATH"], environment: ["PATH": "/usr/bin"])
        #expect(status == 0)
        #expect(output.hasPrefix("/bin:/usr/bin"))
    }

    @Test func theDefaultSetupIsPisOwnFolderNeverTheAppsEnvironment() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(PiConnectorInstaller.defaultSetupFolder(home: home).path == "/Users/me/.pi/agent")
        #expect(PiConnectorInstaller.pluginDir(in: URL(fileURLWithPath: "/scratch/pi"), pluginName: "keyscribe").path == "/scratch/pi/extensions/keyscribe")
    }
}

struct PiConnectorInstallerTests {
    static let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/KeyScribe/Resources/PiConnector/index.ts")
    static let script = PiConnectorFiles.indexTS ?? ""

    private func setup(root: URL? = nil, surfaces: ConnectorSurfaces = .builtIn) -> (PiConnectorInstaller, URL, URL) {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ks-pi-\(UUID().uuidString)")
        let agents = root.appendingPathComponent("agents")
        let folder = root.appendingPathComponent("pi-setup")
        let installer = PiConnectorInstaller(
            setupFolder: folder, pluginName: "keyscribe-dev",
            socketPath: agents.appendingPathComponent("bridge.sock").path,
            tokenPath: agents.appendingPathComponent("token").path,
            readyPath: agents.appendingPathComponent("ready.json").path,
            script: Self.script, surfaces: surfaces)
        return (installer, agents, folder.appendingPathComponent("extensions"))
    }

    @Test func aConnectorInstalledBeforeARouteWasAddedIsRewrittenToCarryItsKeysWithoutAskingOpenConversationsToReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-pi-\(UUID().uuidString)")
        let (before, _, _) = setup(root: root)
        try before.install(installation: "id-1")
        let added = ConnectorSurfaces(environmentKeys: ResolvedSurfaces.builtIn.environmentKeys.union(["MUX_PANE"]), focusDefinitions: ConnectorSurfaces.builtIn.focusDefinitions)
        let (after, _, _) = setup(root: root, surfaces: added)
        #expect(after.installed(installation: "id-1") == .other(version: PiConnectorFiles.version(for: Self.script, surfaces: .builtIn)))
        try after.install(installation: "id-1")
        #expect(after.installed(installation: "id-1") == .current)
        #expect(before.installed(installation: "id-1") == .other(version: PiConnectorFiles.version(for: Self.script, surfaces: added)))
        #expect(PiConnectorFiles.version(for: Self.script, surfaces: added) == PiConnectorFiles.version(for: Self.script, surfaces: .builtIn))
        #expect(ClaudeConnectorFiles.version(for: Self.script, surfaces: added) == ClaudeConnectorFiles.version(for: Self.script, surfaces: .builtIn))
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    @Test func thePackagedConnectorIsTheCheckedInSourceByteForByte() throws {
        #expect(!Self.script.isEmpty)
        #expect(Data(Self.script.utf8) == (try Data(contentsOf: Self.source)))
    }

    @Test func installWritesTheExtensionAndItsSettingsIntoTheChosenSetupsExtensionsFolder() throws {
        let (installer, agents, extensions) = setup()
        try installer.install(installation: "id-1")
        let plugin = extensions.appendingPathComponent("keyscribe-dev")
        let config = try json(plugin.appendingPathComponent("keyscribe.json"))
        #expect(config["protocol"] as? Int == AgentBridgeCodec.protocolVersion)
        #expect(config["socketPath"] as? String == agents.appendingPathComponent("bridge.sock").path)
        #expect(config["tokenPath"] as? String == agents.appendingPathComponent("token").path)
        #expect(config["readyPath"] as? String == agents.appendingPathComponent("ready.json").path)
        #expect(config["plugin"] as? String == "keyscribe-dev")
        #expect(config["appName"] as? String == Branding.appName)
        #expect(config["version"] as? String == PiConnectorFiles.version(for: Self.script, surfaces: .builtIn))
        #expect(Set(config["environmentKeys"] as? [String] ?? []) == ResolvedSurfaces.builtIn.environmentKeys)
        let focus = try #require((config["focusDefinitions"] as? [[String: Any]])?.first { $0["id"] as? String == "cmux" })
        #expect(focus["requiresEnv"] as? [String] == ["CMUX_SURFACE_ID"])
        #expect((focus["argv"] as? [String])?.first == "/usr/bin/env")
        #expect(config["installation"] as? String == "id-1")
        let code = try String(contentsOf: plugin.appendingPathComponent("index.ts"), encoding: .utf8)
        #expect(code.contains("const loadedFrom: string | null = \"id-1\""))
        #expect(code.contains("const configPath: string | null = \"\(plugin.appendingPathComponent("keyscribe.json").path)\""))
        let restored = code
            .replacingOccurrences(of: "const loadedFrom: string | null = \"id-1\"", with: "const loadedFrom: string | null = null")
            .replacingOccurrences(of: "const configPath: string | null = \"\(plugin.appendingPathComponent("keyscribe.json").path)\"", with: "const configPath: string | null = null")
        #expect(restored == Self.script)
        #expect(installer.installed(installation: "id-1") == .current)
        #expect(installer.installed(installation: "id-2") == .other(version: PiConnectorFiles.version(for: Self.script, surfaces: .builtIn)))
        #expect(installer.installed(installation: nil) == .other(version: PiConnectorFiles.version(for: Self.script, surfaces: .builtIn)))
    }

    @Test func uninstallRemovesOnlyTheConnectorsFolder() throws {
        let (installer, _, extensions) = setup()
        let other = extensions.appendingPathComponent("someone-else.ts")
        try installer.install(installation: "id-1")
        try Data("export default function () {}\n".utf8).write(to: other)
        try installer.uninstall()
        #expect(!FileManager.default.fileExists(atPath: extensions.appendingPathComponent("keyscribe-dev").path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        try installer.uninstall()
        #expect(installer.installed(installation: "id-1") == .absent)
    }

    @Test func anOlderOrEditedInstallIsReportedAsAnotherVersion() throws {
        let (installer, _, extensions) = setup()
        #expect(installer.installed(installation: "id-1") == .absent)
        try installer.install(installation: "id-1")
        let plugin = extensions.appendingPathComponent("keyscribe-dev")
        let config = plugin.appendingPathComponent("keyscribe.json")
        var settings = try json(config)
        settings["version"] = "0.1.0-old"
        try JSONSerialization.data(withJSONObject: settings).write(to: config)
        #expect(installer.installed(installation: "id-1") == .other(version: "0.1.0-old"))
        try installer.install(installation: "id-1")
        #expect(installer.installed(installation: "id-1") == .current)
        try Data("edited\n".utf8).write(to: plugin.appendingPathComponent("index.ts"))
        #expect(installer.installed(installation: "id-1") == .other(version: PiConnectorFiles.version(for: Self.script, surfaces: .builtIn)))
    }

    @Test func anExtensionTurnedOffInPisSettingsIsSeen() throws {
        let (installer, _, extensions) = setup()
        try installer.install(installation: "id-1")
        #expect(!installer.turnedOffInPi())
        let settings = extensions.deletingLastPathComponent().appendingPathComponent("settings.json")
        try Data(#"{"extensions": ["-extensions/keyscribe-dev"]}"#.utf8).write(to: settings)
        #expect(installer.turnedOffInPi())
    }

    @Test func theCommandToUninstallByHandNamesTheConnectorsOwnFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/extensions/keyscribe")
        #expect(PiConnectorInstaller.manualUninstall(pluginDir: dir) == ["rm -r ~/.pi/agent/extensions/keyscribe"])
        #expect(PiConnectorInstaller.manualUninstall(pluginDir: URL(fileURLWithPath: "/Users/a/pi work/extensions/keyscribe"), home: "/Users/a")
            == ["rm -r ~/'pi work/extensions/keyscribe'"])
    }

    @Test func theExtensionNeverHardcodesAVariantOrPathAndReadsOnlyTheTerminalFactsItsSettingsName() throws {
        let source = Self.script
        #expect(!source.contains("/Users/"))
        #expect(!source.contains("KeyScribeDev"))
        #expect(source.contains("const configPath: string | null = null"))
        #expect(source.contains("const loadedFrom: string | null = null"))
        #expect(source.contains("const features = [\"focus\", \"focusDefinitions\", \"label\", \"readiness\", \"notify\", \"images\", \"check\"]"))
        #expect(!source.contains("host.env(\""))
        #expect(source.matches(of: try Regex(#"host\.env\(key\)"#)).count == 2)
        #expect(source.contains("const keys = (config && config.environmentKeys) || []"))
        #expect(source.contains("for (const key of definition.requiresEnv)"))
        #expect(!source.contains("tokenPath\""))
    }

    @Test func thePackagedExtensionIsFoundThroughTheSharedResourceLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-found-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("X.bundle/Contents/Resources")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("export default function () {}\n".utf8).write(to: bundle.appendingPathComponent("index.ts"))
        #expect(ConnectorResources.text(named: "index", extension: "ts", searching: [root.appendingPathComponent("missing.bundle"), root.appendingPathComponent("X.bundle")]) == "export default function () {}\n")
        #expect(ConnectorResources.text(named: "index", extension: "ts", searching: [root.appendingPathComponent("missing.bundle")]) == nil)
    }
}

@MainActor
struct PiConnectorStatusTests {
    final class CLI: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var version = "1.5.0\n"
        var status: Int32 = 0
        var calls: [[String]] { lock.withLock { _calls } }

        func run(_ argv: [String]) -> (Int32, String) {
            lock.withLock { _calls.append(argv) }
            return (status, status == 0 ? version : "boom")
        }
    }

    private func make(pi: String? = "/bin/pi-test", cli: CLI = CLI(), script: String? = PiConnectorFiles.indexTS) -> (PiConnector, CLI, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-pi-conn-\(UUID().uuidString)")
        let agents = root.appendingPathComponent("agents")
        let home = root.appendingPathComponent("home")
        let connector = PiConnector(locate: { pi }, run: cli.run, agentsDir: agents, pluginName: "keyscribe-dev", surfaces: .builtIn, script: script, home: home)
        return (connector, cli, agents, home.appendingPathComponent(".pi/agent"))
    }

    private func target(_ folder: URL, installation: String? = "id-1", removing: Bool = false) -> ConnectorTarget {
        ConnectorTarget(folder: folder, isDefault: true, installation: installation, removing: removing)
    }

    @Test func anInstallIsFilesOnlyAndIsSeenAsReadyUntilTheBundledExtensionChanges() async throws {
        let (connector, cli, _, folder) = make()
        #expect(await connector.check(tool: "/bin/pi-test", target: target(folder, installation: nil)) == .status(.notInstalled))
        try await connector.install(tool: "/bin/pi-test", target: target(folder))
        #expect(cli.calls == [["/bin/pi-test", "--version"]])
        #expect(await connector.check(tool: "/bin/pi-test", target: target(folder)) == .status(.ready))
        #expect(connector.hasFiles(in: target(folder)))
        let config = folder.appendingPathComponent("extensions/keyscribe-dev/keyscribe.json")
        var settings = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any] ?? [:]
        settings["version"] = "0.1.0-old"
        try JSONSerialization.data(withJSONObject: settings).write(to: config)
        #expect(await connector.check(tool: "/bin/pi-test", target: target(folder)) == .status(.outdated(installed: "0.1.0-old")))
        try await connector.update(tool: "/bin/pi-test", target: target(folder))
        #expect(await connector.check(tool: "/bin/pi-test", target: target(folder)) == .status(.ready))
    }

    @Test func filesFromAnotherInstallationAreNotThisSetupsConnector() async throws {
        let (connector, _, _, folder) = make()
        try await connector.install(tool: "/bin/pi-test", target: target(folder, installation: "old"))
        #expect(await connector.check(tool: "/bin/pi-test", target: target(folder, installation: nil)) == .status(.notInstalled))
    }

    @Test func aConnectorTurnedOffInPiReadsAsDisabled() async throws {
        let (connector, _, _, folder) = make()
        try await connector.install(tool: "/bin/pi-test", target: target(folder))
        try Data(#"{"extensions": ["!extensions/*"]}"#.utf8).write(to: folder.appendingPathComponent("settings.json"))
        #expect(await connector.check(tool: "/bin/pi-test", target: target(folder)) == .status(.disabled))
    }

    @Test func theVersionIsAskedOnceUntilTheToolChangesOnDisk() async throws {
        let (connector, cli, _, folder) = make()
        _ = await connector.check(tool: "/bin/pi-test", target: target(folder))
        _ = await connector.check(tool: "/bin/pi-test", target: target(folder))
        #expect(cli.calls.count == 1)
        let tool = FileManager.default.temporaryDirectory.appendingPathComponent("ks-pi-tool-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        _ = await connector.check(tool: tool.path, target: target(folder))
        _ = await connector.check(tool: tool.path, target: target(folder))
        #expect(cli.calls.count == 2)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: tool.path)
        _ = await connector.check(tool: tool.path, target: target(folder))
        #expect(cli.calls.count == 3)
    }

    @Test func aPiBelowTheFloorIsReportedBeforeAnyFileIsLooked() async {
        let cli = CLI()
        cli.version = "1.3.2\n"
        let (connector, _, _, folder) = make(cli: cli)
        #expect(await connector.check(tool: "/bin/pi-test", target: target(folder)) == .toolTooOld("1.3.2"))
        #expect(connector.copy.toolTooOldAdvice("1.3.2").contains("1.4.0"))
    }

    @Test func aPiThatCannotReportItsVersionFailsWithWhatItSaid() async {
        let cli = CLI()
        cli.status = 1
        let (connector, _, _, folder) = make(cli: cli)
        #expect(await connector.check(tool: "/bin/pi-test", target: target(folder)) == .failed("boom"))
    }

    @Test func leftoverFilesOfASetupBeingRemovedReadAsUnfinished() async throws {
        let (connector, _, _, folder) = make()
        try await connector.install(tool: "/bin/pi-test", target: target(folder))
        #expect(await connector.check(tool: "/bin/pi-test", target: target(folder, removing: true)) == .removalUnfinished(nil))
        try await connector.uninstall(tool: "/bin/pi-test", target: target(folder, removing: true))
        #expect(!connector.hasFiles(in: target(folder)))
        #expect(await connector.check(tool: "/bin/pi-test", target: target(folder, removing: true)) == .status(.notInstalled))
        #expect(connector.manualUninstall(for: target(folder)) == ["rm -r \((folder.appendingPathComponent("extensions/keyscribe-dev").path as NSString).abbreviatingWithTildeInPath)"])
    }

    @Test func aMissingBundledExtensionIsUnavailable() async {
        let (connector, cli, _, folder) = make(script: nil)
        #expect(!connector.isBundled)
        #expect(await connector.check(tool: "/bin/pi-test", target: target(folder)) == .unavailable)
        await #expect(throws: AgentConnectorError.self) { try await connector.install(tool: "/bin/pi-test", target: target(folder)) }
        #expect(cli.calls.isEmpty)
    }

    @Test func theSettingsModelInstallsIntoOneSetupAndUninstallLeavesItsRecordGone() async throws {
        let (connector, _, agents, folder) = make()
        let model = CodingAgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [connector])
        await model.refresh()
        let setup = try #require(model.connectors[0].setups.first)
        #expect(setup.folder.path == ConnectorFolders.canonical(folder).path)
        #expect(setup.state == .status(.notInstalled))
        await setup.install()
        #expect(setup.state == .status(.ready))
        #expect(model.setups.setups?.enrolled(agent: "pi").count == 1)
        var retired: [String] = []
        model.onRetire = { retired.append($0) }
        let installation = try #require(setup.target.installation)
        await setup.remove()
        #expect(retired == [installation])
        #expect(setup.state == .status(.notInstalled))
        #expect(model.setups.setups?.setups.isEmpty == true)
        #expect(!model.setups.admits(agent: "pi", installation: installation))
    }

    @Test(arguments: [false, true])
    func aRouteThatAddsKeysUpdatesTheFilesAndAsksOpenConversationsToReloadOnlyWhenItAddsAFocusCommand(addsFocus: Bool) async throws {
        let (before, _, agents, folder) = make()
        let model = CodingAgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [before])
        await model.refresh()
        await model.connectors[0].setups[0].install()
        let loaded = try #require(before.bundledVersion)

        let focus = FocusDefinition(id: "mux", requiresEnv: ["MUX_PANE"], argv: ["/usr/bin/env", "mux", "focus", "{MUX_PANE}"])
        let definitions = ConnectorSurfaces.builtIn.focusDefinitions + (addsFocus ? [focus] : [])
        let after = PiConnector(
            locate: { "/bin/pi-test" }, run: CLI().run, agentsDir: agents, pluginName: "keyscribe-dev",
            surfaces: ConnectorSurfaces(environmentKeys: ResolvedSurfaces.builtIn.environmentKeys.union(["MUX_PANE"]), focusDefinitions: definitions),
            script: PiConnectorFiles.indexTS, home: folder.deletingLastPathComponent().deletingLastPathComponent())
        let updated = CodingAgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [after])
        await updated.refresh()
        let setup = updated.connectors[0].setups[0]
        #expect(setup.state == .status(.outdated(installed: loaded)))
        await setup.update()
        #expect(setup.state == .status(.ready))
        #expect(CodingAgentsSettingsModel.older(loaded, than: after.bundledVersion) == addsFocus)
        #expect(!CodingAgentsSettingsModel.older(after.bundledVersion, than: after.bundledVersion))
    }

    @Test func installingOneSetupLeavesAnotherUntouched() async throws {
        let (connector, _, agents, folder) = make()
        let other = agents.deletingLastPathComponent().appendingPathComponent("pi-work")
        let model = CodingAgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [connector])
        model.show([], current: nil, discoveredSetups: ["pi": [ConnectorFolders.canonical(other).path]])
        let work = try #require(model.connectors[0].setup(for: ConnectorFolders.canonical(other).path))
        await work.install()
        #expect(connector.hasFiles(in: target(other)))
        #expect(!connector.hasFiles(in: target(folder)))
        #expect(model.setups.setups?.enrolled(agent: "pi").map(\.folder) == [ConnectorFolders.canonical(other).path])
    }

    @Test func withoutPiAnInstalledConnectorStillOffersTheCommandToFinishByHand() async throws {
        let (installed, _, agents, folder) = make()
        let model = CodingAgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [installed])
        await model.refresh()
        await model.connectors[0].setups[0].install()
        let connector = PiConnector(
            locate: { nil }, run: { _ in (0, "") }, agentsDir: agents, pluginName: "keyscribe-dev", surfaces: .builtIn, script: PiConnectorFiles.indexTS,
            home: folder.deletingLastPathComponent().deletingLastPathComponent())
        let without = CodingAgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [connector])
        await without.refresh()
        #expect(without.connectors[0].setups[0].state == .toolNotFound)
        #expect(without.connectors[0].setups[0].manualUninstall.first?.hasPrefix("rm -r ") == true)
        #expect(without.connectors[0].setups[0].canUninstallWithoutTool)
    }
}
