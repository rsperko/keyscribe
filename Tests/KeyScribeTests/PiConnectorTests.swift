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

    @Test func theExtensionsFolderFollowsPisOwnDirectoryVariable() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(PiConnectorInstaller.defaultExtensionsDir(environment: [:], home: home).path == "/Users/me/.pi/agent/extensions")
        #expect(PiConnectorInstaller.defaultExtensionsDir(environment: ["PI_CODING_AGENT_DIR": "/scratch/pi"], home: home).path == "/scratch/pi/extensions")
        #expect(PiConnectorInstaller.defaultExtensionsDir(environment: ["PI_CODING_AGENT_DIR": ""], home: home).path == "/Users/me/.pi/agent/extensions")
    }
}

struct PiConnectorInstallerTests {
    static let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/KeyScribe/Resources/PiConnector/index.ts")
    static let script = PiConnectorFiles.indexTS ?? ""

    private func setup() -> (PiConnectorInstaller, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-pi-\(UUID().uuidString)")
        let agents = root.appendingPathComponent("agents")
        let extensions = root.appendingPathComponent("extensions")
        let installer = PiConnectorInstaller(
            extensionsDir: extensions, agentsDir: agents, pluginName: "keyscribe-dev",
            socketPath: agents.appendingPathComponent("bridge.sock").path,
            tokenPath: agents.appendingPathComponent("token").path,
            readyPath: agents.appendingPathComponent("ready.json").path,
            script: Self.script)
        return (installer, agents, extensions)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    @Test func thePackagedConnectorIsTheCheckedInSourceByteForByte() throws {
        #expect(!Self.script.isEmpty)
        #expect(Data(Self.script.utf8) == (try Data(contentsOf: Self.source)))
    }

    @Test func installWritesTheExtensionAndItsSettingsIntoPisExtensionsFolder() throws {
        let (installer, agents, extensions) = setup()
        try installer.install()
        let plugin = extensions.appendingPathComponent("keyscribe-dev")
        let config = try json(plugin.appendingPathComponent("keyscribe.json"))
        #expect(config["protocol"] as? Int == AgentBridgeCodec.protocolVersion)
        #expect(config["socketPath"] as? String == agents.appendingPathComponent("bridge.sock").path)
        #expect(config["tokenPath"] as? String == agents.appendingPathComponent("token").path)
        #expect(config["readyPath"] as? String == agents.appendingPathComponent("ready.json").path)
        #expect(config["plugin"] as? String == "keyscribe-dev")
        #expect(config["version"] as? String == PiConnectorFiles.version(for: Self.script))
        #expect(Set(config["environmentKeys"] as? [String] ?? []) == TerminalRoutes.environmentKeys)
        let id = try #require(config["installation"] as? String)
        #expect(PiConnectorInstaller.currentInstallation(in: agents) == id)
        let code = try String(contentsOf: plugin.appendingPathComponent("index.ts"), encoding: .utf8)
        #expect(code.contains("const loadedFrom: string | null = \"\(id)\""))
        #expect(code.contains("const configPath: string | null = \"\(plugin.appendingPathComponent("keyscribe.json").path)\""))
        let restored = code
            .replacingOccurrences(of: "const loadedFrom: string | null = \"\(id)\"", with: "const loadedFrom: string | null = null")
            .replacingOccurrences(of: "const configPath: string | null = \"\(plugin.appendingPathComponent("keyscribe.json").path)\"", with: "const configPath: string | null = null")
        #expect(restored == Self.script)
        #expect(installer.installed() == .current)
    }

    @Test func eachInstallGetsANewInstallationAndAnUpdateKeepsIt() throws {
        let (installer, agents, _) = setup()
        try installer.install()
        let first = try #require(PiConnectorInstaller.currentInstallation(in: agents))
        try installer.install()
        let second = try #require(PiConnectorInstaller.currentInstallation(in: agents))
        #expect(first != second)
        try installer.update()
        #expect(PiConnectorInstaller.currentInstallation(in: agents) == second)
        #expect(installer.installed() == .current)
    }

    @Test func uninstallRetiresTheInstallationThenRemovesOnlyTheConnectorsFolder() throws {
        let (installer, agents, extensions) = setup()
        let other = extensions.appendingPathComponent("someone-else.ts")
        try installer.install()
        try Data("export default function () {}\n".utf8).write(to: other)
        try installer.uninstall()
        #expect(PiConnectorInstaller.wasRemoved(in: agents))
        #expect(PiConnectorInstaller.currentInstallation(in: agents) == nil)
        #expect(!FileManager.default.fileExists(atPath: extensions.appendingPathComponent("keyscribe-dev").path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: agents.appendingPathComponent(PiConnectorInstaller.installationFile).path))
        try installer.uninstall()
        #expect(installer.installed() == .absent)
    }

    @Test func anOlderOrEditedInstallIsReportedAsAnotherVersion() throws {
        let (installer, _, extensions) = setup()
        #expect(installer.installed() == .absent)
        try installer.install()
        let plugin = extensions.appendingPathComponent("keyscribe-dev")
        let config = plugin.appendingPathComponent("keyscribe.json")
        var settings = try json(config)
        settings["version"] = "0.1.0-old"
        try JSONSerialization.data(withJSONObject: settings).write(to: config)
        #expect(installer.installed() == .other(version: "0.1.0-old"))
        try installer.update()
        #expect(installer.installed() == .current)
        try Data("edited\n".utf8).write(to: plugin.appendingPathComponent("index.ts"))
        #expect(installer.installed() == .other(version: PiConnectorFiles.version(for: Self.script)))
    }

    @Test func theCommandToUninstallByHandNamesTheConnectorsOwnFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/extensions/keyscribe")
        #expect(PiConnectorInstaller.manualUninstall(pluginDir: dir) == ["rm -r ~/.pi/agent/extensions/keyscribe"])
    }

    @Test func theExtensionNeverHardcodesAVariantOrPathAndReadsOnlyTheTerminalFactsItsSettingsName() throws {
        let source = Self.script
        #expect(!source.contains("/Users/"))
        #expect(!source.contains("KeyScribeDev"))
        #expect(source.contains("const configPath: string | null = null"))
        #expect(source.contains("const loadedFrom: string | null = null"))
        #expect(source.contains("const features = [\"focus\", \"label\", \"readiness\"]"))
        let reads = try Regex(#"host\.env\("([A-Z_]+)"\)"#)
        #expect(source.matches(of: reads).compactMap { $0.output[1].substring.map(String.init) } == ["CMUX_SURFACE_ID"])
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
        let extensions = root.appendingPathComponent("extensions")
        let connector = PiConnector(locate: { pi }, run: cli.run, agentsDir: agents, extensionsDir: extensions, pluginName: "keyscribe-dev", script: script)
        return (connector, cli, agents, extensions)
    }

    @Test func anInstallIsFilesOnlyAndIsSeenAsReadyUntilTheBundledExtensionChanges() async throws {
        let (connector, cli, _, extensions) = make()
        #expect(await connector.check(tool: "/bin/pi-test") == .status(.notInstalled))
        try await connector.install(tool: "/bin/pi-test")
        #expect(cli.calls == [["/bin/pi-test", "--version"]])
        #expect(await connector.check(tool: "/bin/pi-test") == .status(.ready))
        #expect(connector.hasFiles)
        var settings = try JSONSerialization.jsonObject(with: Data(contentsOf: extensions.appendingPathComponent("keyscribe-dev/keyscribe.json"))) as? [String: Any] ?? [:]
        settings["version"] = "0.1.0-old"
        try JSONSerialization.data(withJSONObject: settings).write(to: extensions.appendingPathComponent("keyscribe-dev/keyscribe.json"))
        #expect(await connector.check(tool: "/bin/pi-test") == .status(.outdated(installed: "0.1.0-old")))
        try await connector.update(tool: "/bin/pi-test")
        #expect(await connector.check(tool: "/bin/pi-test") == .status(.ready))
    }

    @Test func theVersionIsAskedOnceUntilTheToolChangesOnDisk() async throws {
        let (connector, cli, _, _) = make()
        _ = await connector.check(tool: "/bin/pi-test")
        _ = await connector.check(tool: "/bin/pi-test")
        #expect(cli.calls.count == 1)
        let tool = FileManager.default.temporaryDirectory.appendingPathComponent("ks-pi-tool-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        _ = await connector.check(tool: tool.path)
        _ = await connector.check(tool: tool.path)
        #expect(cli.calls.count == 2)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: tool.path)
        _ = await connector.check(tool: tool.path)
        #expect(cli.calls.count == 3)
    }

    @Test func aPiBelowTheFloorIsReportedBeforeAnyFileIsLooked() async {
        let cli = CLI()
        cli.version = "1.3.2\n"
        let (connector, _, _, _) = make(cli: cli)
        #expect(await connector.check(tool: "/bin/pi-test") == .toolTooOld("1.3.2"))
        #expect(connector.copy.toolTooOldAdvice("1.3.2").contains("1.4.0"))
    }

    @Test func aConnectorInstalledUnderAPiThatIsNowTooOldStillOffersUninstall() async throws {
        let cli = CLI()
        let (connector, _, agents, _) = make(cli: cli)
        try await connector.install(tool: "/bin/pi-test")
        cli.version = "1.3.2\n"
        let model = CodingAgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [connector])
        await model.refresh()
        #expect(model.connectors[0].state == .toolTooOld("1.3.2"))
        #expect(model.connectors[0].offersUninstall)
        #expect(model.connectors[0].manualUninstall.isEmpty)
        await model.connectors[0].remove()
        #expect(!connector.hasFiles)
        #expect(model.connectors[0].state == .toolTooOld("1.3.2"))
        #expect(!model.connectors[0].offersUninstall)
    }

    @Test func aPiThatCannotReportItsVersionFailsWithWhatItSaid() async {
        let cli = CLI()
        cli.status = 1
        let (connector, _, _, _) = make(cli: cli)
        #expect(await connector.check(tool: "/bin/pi-test") == .failed("boom"))
    }

    @Test func anUninstallRemovesTheFolderAndLeftoverFilesReadAsUnfinished() async throws {
        let (connector, _, agents, extensions) = make()
        try await connector.install(tool: "/bin/pi-test")
        try connector.disable()
        #expect(connector.wasRemoved)
        #expect(await connector.check(tool: "/bin/pi-test") == .removalUnfinished(nil))
        try await connector.uninstall(tool: "/bin/pi-test")
        #expect(!connector.hasFiles)
        #expect(await connector.check(tool: "/bin/pi-test") == .status(.notInstalled))
        #expect(FileManager.default.fileExists(atPath: agents.appendingPathComponent("pi-installation.json").path))
        #expect(connector.manualUninstall == ["rm -r \((extensions.appendingPathComponent("keyscribe-dev").path as NSString).abbreviatingWithTildeInPath)"])
    }

    @Test func aMissingBundledExtensionIsUnavailable() async {
        let (connector, cli, _, _) = make(script: nil)
        #expect(!connector.isBundled)
        #expect(await connector.check(tool: "/bin/pi-test") == .unavailable)
        await #expect(throws: AgentConnectorError.self) { try await connector.install(tool: "/bin/pi-test") }
        #expect(cli.calls.isEmpty)
    }

    @Test func theSettingsModelDrivesThePiConnectorLikeAnyOther() async {
        let (connector, _, agents, _) = make()
        let model = CodingAgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [connector])
        await model.refresh()
        #expect(model.connectors.map(\.id) == ["pi"])
        #expect(model.connectors[0].state == .status(.notInstalled))
        await model.connectors[0].install()
        #expect(model.connectors[0].state == .status(.ready))
        #expect(model.connectors[0].needsReload)
        #expect(model.connectors[0].copy.reloadHint.contains("/reload"))
        await model.connectors[0].remove()
        #expect(model.connectors[0].state == .status(.notInstalled))
        #expect(!model.connectors[0].needsReload)
    }

    @Test func withoutPiAnInstalledConnectorStillOffersTheCommandToFinishByHand() async throws {
        let (installed, _, agents, extensions) = make()
        try await installed.install(tool: "/bin/pi-test")
        let (connector, _, _, _) = (PiConnector(locate: { nil }, run: { _ in (0, "") }, agentsDir: agents, extensionsDir: extensions, pluginName: "keyscribe-dev", script: PiConnectorFiles.indexTS), (), (), ())
        let model = CodingAgentsSettingsModel(describeTerminal: { _ in nil }, agentsDir: agents, connectors: [connector])
        await model.refresh()
        #expect(model.connectors[0].state == .toolNotFound)
        #expect(model.connectors[0].manualUninstall.first?.hasPrefix("rm -r ") == true)
        #expect(model.connectors[0].canUninstallWithoutTool)
    }
}
