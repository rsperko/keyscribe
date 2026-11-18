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
        #expect(ExtensionAgent.pi.isSupported(PiCLI.version(in: "1.4\n") ?? []))
    }

    @Test func versionsBelowTheFloorAreNotSupported() {
        #expect(ExtensionAgent.pi.isSupported([1, 4, 0]))
        #expect(ExtensionAgent.pi.isSupported([1, 5, 0]))
        #expect(ExtensionAgent.pi.isSupported([2, 0]))
        #expect(!ExtensionAgent.pi.isSupported([1, 3, 9]))
        #expect(!ExtensionAgent.pi.isSupported([0, 80, 3]))
        #expect(ExtensionAgent.describe([1, 4, 0]) == "1.4.0")
    }

    @Test func piIsAlsoLookedForUnderTheNewestNodeVersionManagerInstallFirst() {
        let home = URL(fileURLWithPath: "/Users/me")
        let listing: (URL) -> [String] = { $0.path.hasSuffix(".nvm/versions/node") ? ["v22.1.0", "v24.21.0", "v9.0.0"] : [] }
        #expect(PiCLI.extraFolders(home: home, listing: listing) == [
            "/Users/me/.nvm/versions/node/v24.21.0/bin", "/Users/me/.nvm/versions/node/v22.1.0/bin", "/Users/me/.nvm/versions/node/v9.0.0/bin",
            "/Users/me/.bun/bin", "/Users/me/.npm-global/bin",
        ])
    }

    @Test func theDefaultSetupIsPisOwnFolderNeverTheAppsEnvironment() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(ExtensionAgent.pi.rule.defaultFolder(home: home).path == "/Users/me/.pi/agent")
        #expect(ExtensionConnectorInstaller.pluginDir(in: URL(fileURLWithPath: "/scratch/pi"), pluginName: "keyscribe").path == "/scratch/pi/extensions/keyscribe")
    }
}

struct PiConnectorInstallerTests {
    static let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/KeyScribe/Resources/PiConnector/index.ts")
    static let script = ExtensionConnectorFiles.indexTS ?? ""

    private func setup(root: URL? = nil, surfaces: ConnectorSurfaces = .builtIn) -> (ExtensionConnectorInstaller, URL, URL) {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ks-pi-\(UUID().uuidString)")
        let agents = root.appendingPathComponent("agents")
        let folder = root.appendingPathComponent("pi-setup")
        let installer = ExtensionConnectorInstaller(
            agent: .pi,
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
        #expect(after.installed(installation: "id-1") == .other(version: ExtensionConnectorFiles.version(for: Self.script, surfaces: .builtIn)))
        try after.install(installation: "id-1")
        #expect(after.installed(installation: "id-1") == .current)
        #expect(before.installed(installation: "id-1") == .other(version: ExtensionConnectorFiles.version(for: Self.script, surfaces: added)))
        #expect(ExtensionConnectorFiles.version(for: Self.script, surfaces: added) == ExtensionConnectorFiles.version(for: Self.script, surfaces: .builtIn))
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
        #expect(config["version"] as? String == ExtensionConnectorFiles.version(for: Self.script, surfaces: .builtIn))
        #expect(Set(config["environmentKeys"] as? [String] ?? []) == ResolvedSurfaces.builtIn.environmentKeys)
        let focus = try #require((config["focusDefinitions"] as? [[String: Any]])?.first { $0["id"] as? String == "cmux" })
        #expect(focus["requiresEnv"] as? [String] == ["CMUX_SURFACE_ID"])
        #expect((focus["argv"] as? [String])?.first == "/usr/bin/env")
        #expect(config["installation"] as? String == "id-1")
        let code = try String(contentsOf: plugin.appendingPathComponent("index.ts"), encoding: .utf8)
        #expect(code.contains("const loadedFrom: string | null = \"id-1\""))
        #expect(code.contains("const installedFor: string | null = \"pi\""))
        let version = ExtensionConnectorFiles.version(for: Self.script, surfaces: .builtIn)
        #expect(code.contains("const builtVersion: string | null = \"\(version)\""))
        #expect(code.contains("const configPath: string | null = \"\(plugin.appendingPathComponent("keyscribe.json").path)\""))
        let restored = code
            .replacingOccurrences(of: "const loadedFrom: string | null = \"id-1\"", with: "const loadedFrom: string | null = null")
            .replacingOccurrences(of: "const installedFor: string | null = \"pi\"", with: "const installedFor: string | null = null")
            .replacingOccurrences(of: "const builtVersion: string | null = \"\(version)\"", with: "const builtVersion: string | null = null")
            .replacingOccurrences(of: "const configPath: string | null = \"\(plugin.appendingPathComponent("keyscribe.json").path)\"", with: "const configPath: string | null = null")
        #expect(restored == Self.script)
        #expect(installer.installed(installation: "id-1") == .current)
        #expect(installer.installed(installation: "id-2") == .other(version: ExtensionConnectorFiles.version(for: Self.script, surfaces: .builtIn)))
        #expect(installer.installed(installation: nil) == .other(version: ExtensionConnectorFiles.version(for: Self.script, surfaces: .builtIn)))
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
        #expect(installer.installed(installation: "id-1") == .other(version: ExtensionConnectorFiles.version(for: Self.script, surfaces: .builtIn)))
    }

    @Test func anExtensionTurnedOffInPisSettingsIsSeen() throws {
        let (installer, _, extensions) = setup()
        try installer.install(installation: "id-1")
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(PiCLI.turnedOff(setupFolder: installer.setupFolder, pluginDir: installer.pluginDir, home: home) == .no)
        let settings = extensions.deletingLastPathComponent().appendingPathComponent("settings.json")
        try Data(#"{"theme": "dark"}"#.utf8).write(to: settings)
        #expect(PiCLI.turnedOff(setupFolder: installer.setupFolder, pluginDir: installer.pluginDir, home: home) == .no)
        try Data(#"{"extensions": ["-extensions/keyscribe-dev"]}"#.utf8).write(to: settings)
        #expect(PiCLI.turnedOff(setupFolder: installer.setupFolder, pluginDir: installer.pluginDir, home: home) == .yes)
    }

    @Test(arguments: ["", "   ", #"{"extensions": ["-extensions/keyscribe-dev""#, #"["-extensions/keyscribe-dev"]"#, "null"])
    func settingsPiStartsWithoutBecauseItCannotReadThemLeaveTheConnectorOn(text: String) throws {
        let (installer, _, extensions) = setup()
        try installer.install(installation: "id-1")
        try Data(text.utf8).write(to: extensions.deletingLastPathComponent().appendingPathComponent("settings.json"))
        #expect(PiCLI.turnedOff(setupFolder: installer.setupFolder, pluginDir: installer.pluginDir, home: FileManager.default.homeDirectoryForCurrentUser) == .no)
    }

    @Test(arguments: [#"{"extensions": "-extensions/keyscribe-dev"}"#, #"{"extensions": {"-extensions/keyscribe-dev": true}}"#, #"{"extensions": [1]}"#])
    func anExtensionsSettingThatIsNotAListOfEntriesIsUnknown(text: String) throws {
        let (installer, _, extensions) = setup()
        try installer.install(installation: "id-1")
        try Data(text.utf8).write(to: extensions.deletingLastPathComponent().appendingPathComponent("settings.json"))
        guard case .unknown(let reason) = PiCLI.turnedOff(setupFolder: installer.setupFolder, pluginDir: installer.pluginDir, home: FileManager.default.homeDirectoryForCurrentUser) else {
            Issue.record("read as known")
            return
        }
        #expect(reason.contains("settings.json"))
    }

    @Test func theCopySpeaksOfConversationsAndNamesPisReloadCommandWhereOneIsNeeded() {
        let copy = AgentConnectorCopy.extensionAgent(.pi)
        let reloading = [copy.reloadHint, copy.uninstallMessage, copy.manualUninstallLead, copy.manualUninstallAfterDisconnect, copy.stillConnected(1), copy.stillConnected(2)]
        for text in reloading { #expect(text.contains("/reload"), "\(text)") }
        for text in reloading + [copy.help, copy.removalUnfinishedAdvice, copy.toolNotFoundAdvice] {
            #expect(!text.lowercased().contains("session"), "\(text)")
        }
        #expect(copy.toolNotFoundAdvice.hasSuffix("the usual install folders, and under Node version managers."))
        #expect(copy.uninstallTitle == "Uninstall the Pi connector from this folder?")
    }

    @Test func theCommandToUninstallByHandNamesTheConnectorsOwnFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/extensions/keyscribe")
        #expect(ExtensionConnectorInstaller.manualUninstall(pluginDir: dir) == ["rm -r ~/.pi/agent/extensions/keyscribe"])
        #expect(ExtensionConnectorInstaller.manualUninstall(pluginDir: URL(fileURLWithPath: "/Users/a/pi work/extensions/keyscribe"), home: "/Users/a")
            == ["rm -r ~/'pi work/extensions/keyscribe'"])
    }

    @Test func theExtensionNeverHardcodesAVariantOrPathAndReadsOnlyTheTerminalFactsItsSettingsName() throws {
        let source = Self.script
        #expect(!source.contains("/Users/"))
        #expect(!source.contains("KeyScribeDev"))
        #expect(source.contains("const configPath: string | null = null"))
        #expect(source.contains("const loadedFrom: string | null = null"))
        #expect(source.contains("const features = [\"focus\", \"focusDefinitions\", \"label\", \"readiness\", \"notify\", \"images\", \"check\", \"steer\", \"merge\"]"))
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

        func check(_ tool: String) async -> ToolCheck {
            let (version, status) = lock.withLock {
                _calls.append([tool, "--version"])
                return (self.version, self.status)
            }
            return ToolCheck.judge(.exited(status), output: status == 0 ? version : "boom")
        }
    }

    private func make(pi: String? = "/bin/pi-test", cli: CLI = CLI(), script: String? = ExtensionConnectorFiles.indexTS) -> (ExtensionConnector, CLI, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-pi-conn-\(UUID().uuidString)")
        let agents = root.appendingPathComponent("agents")
        let home = root.appendingPathComponent("home")
        let tools = ToolEnvironment(appEnvironment: ["PATH": "/test-bin"], shell: "/bin/zsh", isExecutable: { pi != nil && $0 == "/test-bin/pi" })
        let connector = ExtensionConnector(agent: .pi, version: cli.check, tools: tools, agentsDir: agents, pluginName: "keyscribe-dev", surfaces: .builtIn, script: script, home: home)
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

    @MainActor @Test func aConnectorLostOutsideTheAppOffersReinstallAndUninstallWhileItsSetupIsEnrolled() async throws {
        let (connector, cli, agents, folder) = make()
        let setup = ConnectorSetupModel(
            folder: folder, isDefault: true, connector: connector, registry: ConnectorSetupRegistry(directory: agents), retire: { _ in })
        cli.status = 1
        await setup.install()
        #expect(setup.toolMissing)
        #expect(!setup.isInstalled)
        #expect(setup.isEnrolled)
        #expect(setup.offersUninstall)
        cli.status = 0
        await setup.retry()
        #expect(setup.state == .status(.ready))
        #expect(!setup.offersReinstall)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("extensions/keyscribe-dev"))
        await setup.refresh()
        #expect(setup.state == .status(.notInstalled))
        #expect(setup.offersReinstall)
        #expect(setup.offersUninstall)
        await setup.install()
        #expect(setup.state == .status(.ready))
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

    @MainActor @Test func aConnectorWhoseExtensionsSettingIsNotAListIsInstalledButUnconfirmed() async throws {
        let (connector, _, agents, folder) = make()
        let setup = ConnectorSetupModel(
            folder: folder, isDefault: true, connector: connector, registry: ConnectorSetupRegistry(directory: agents), retire: { _ in })
        await setup.install()
        try Data(#"{"extensions": "-extensions/keyscribe-dev"}"#.utf8).write(to: folder.appendingPathComponent("settings.json"))
        await setup.refresh()
        guard case .unconfirmed = setup.state else {
            Issue.record("\(setup.state)")
            return
        }
        #expect(setup.isInstalled)
        #expect(setup.hasError)
        #expect(setup.offersUninstall)
        #expect(!setup.offersReinstall)
        try Data(#"{"extensions": []}"#.utf8).write(to: folder.appendingPathComponent("settings.json"))
        await setup.refresh()
        #expect(setup.state == .status(.ready))
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
        #expect(await connector.check(tool: "/bin/pi-test", target: target(folder)) == .toolNotWorking(.exited(1, "boom")))
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
        let model = AgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [connector])
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
        let model = AgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [before])
        await model.refresh()
        await model.connectors[0].setups[0].install()
        let loaded = try #require(before.bundledVersion)

        let focus = FocusDefinition(id: "mux", requiresEnv: ["MUX_PANE"], argv: ["/usr/bin/env", "mux", "focus", "{MUX_PANE}"])
        let definitions = ConnectorSurfaces.builtIn.focusDefinitions + (addsFocus ? [focus] : [])
        let after = ExtensionConnector(agent: .pi,
            version: CLI().check, tools: ToolEnvironment(appEnvironment: ["PATH": "/test-bin"], shell: "/bin/zsh", isExecutable: { $0 == "/test-bin/pi" }),
            agentsDir: agents, pluginName: "keyscribe-dev",
            surfaces: ConnectorSurfaces(environmentKeys: ResolvedSurfaces.builtIn.environmentKeys.union(["MUX_PANE"]), focusDefinitions: definitions),
            script: ExtensionConnectorFiles.indexTS, home: folder.deletingLastPathComponent().deletingLastPathComponent())
        let updated = AgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [after])
        await updated.refresh()
        let setup = updated.connectors[0].setups[0]
        #expect(setup.state == .status(.outdated(installed: loaded)))
        await setup.update()
        #expect(setup.state == .status(.ready))
        #expect((loaded != after.bundledVersion) == addsFocus)
    }

    @Test func installingOneSetupLeavesAnotherUntouched() async throws {
        let (connector, _, agents, folder) = make()
        let other = agents.deletingLastPathComponent().appendingPathComponent("pi-work")
        let model = AgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [connector])
        model.show([], discoveredSetups: ["pi": [ConnectorFolders.canonical(other).path]])
        let work = try #require(model.connectors[0].setup(for: ConnectorFolders.canonical(other).path))
        await work.install()
        #expect(connector.hasFiles(in: target(other)))
        #expect(!connector.hasFiles(in: target(folder)))
        #expect(model.setups.setups?.enrolled(agent: "pi").map(\.folder) == [ConnectorFolders.canonical(other).path])
    }

    @Test func withoutPiAnInstalledConnectorStillOffersTheCommandToFinishByHand() async throws {
        let (installed, _, agents, folder) = make()
        let model = AgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [installed])
        await model.refresh()
        await model.connectors[0].setups[0].install()
        let connector = ExtensionConnector(agent: .pi,
            version: { _ in .working("1.5.0") }, tools: ToolEnvironment(appEnvironment: ["PATH": "/test-bin"], shell: "/bin/zsh", isExecutable: { _ in false }),
            agentsDir: agents, pluginName: "keyscribe-dev", surfaces: .builtIn, script: ExtensionConnectorFiles.indexTS,
            home: folder.deletingLastPathComponent().deletingLastPathComponent())
        let without = AgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [connector])
        await without.refresh()
        #expect(without.connectors[0].setups[0].state == .toolNotFound)
        #expect(without.connectors[0].setups[0].manualUninstall.first?.hasPrefix("rm -r ") == true)
        #expect(without.connectors[0].setups[0].canUninstallWithoutTool)
    }
}
