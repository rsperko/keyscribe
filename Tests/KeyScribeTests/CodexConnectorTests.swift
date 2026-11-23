import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
@Suite(.serialized)
struct CodexConnectorTests {
    final class Codex: @unchecked Sendable {
        let lock = NSLock()
        var calls: [(argv: [String], environment: [String: String])] = []
        var answers: [String: HostCLI.Output] = [:]
        var installedPath: String?
        var enabled = true

        func answer(_ subcommand: String, status: Int32 = 0, stdout: String = "", stderr: String = "") {
            lock.withLock { answers[subcommand] = HostCLI.Output(status: status, stdout: Data(stdout.utf8), stderr: stderr, truncated: false) }
        }

        func run(_ argv: [String], _ subcommand: String, _ environment: [String: String]) -> HostCLI.Output {
            lock.withLock {
                calls.append((argv, environment))
                if let fixed = answers[subcommand] { return fixed }
                if subcommand == "plugin list" {
                    let listed = installedPath.map {
                        #"[{"pluginId":"keyscribe@keyscribe-local","installed":true,"enabled":\#(enabled),"source":{"source":"local","path":"\#($0)"}}]"#
                    } ?? "[]"
                    return HostCLI.Output(status: 0, stdout: Data(#"{"installed":\#(listed),"available":[]}"#.utf8), stderr: "", truncated: false)
                }
                return HostCLI.Output(status: 0, stdout: Data("{}".utf8), stderr: "", truncated: false)
            }
        }

        var subcommands: [String] { lock.withLock { calls.map { $0.argv.dropFirst().prefix(3).joined(separator: " ") } } }
    }

    final class Trust: @unchecked Sendable {
        var result: CodexPlugin.Trust? = .trusted
    }

    struct Rig {
        var connector: CodexConnector
        var codex: Codex
        var trust: Trust
        var agents: URL
        var home: URL
        var target: ConnectorTarget
        var config: URL { home.appendingPathComponent("config.toml") }
    }

    private func rig(config: String? = nil, installation: String = "inst-1") throws -> Rig {
        let root = URL(fileURLWithPath: "/tmp/ks-cxc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let agents = root.appendingPathComponent("agents dir", isDirectory: true)
        let home = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let config { try Data(config.utf8).write(to: home.appendingPathComponent("config.toml")) }
        let codex = Codex()
        let trust = Trust()
        let connector = CodexConnector(
            agentsDir: agents, pluginName: "keyscribe", home: root, script: "#!/bin/sh\nagents=__AGENTS_DIR__\napp=\"__APP_NAME__\"\n",
            run: { argv, subcommand, _, environment in codex.run(argv, subcommand, environment) }, trust: { _, _ in trust.result })
        return Rig(
            connector: connector, codex: codex, trust: trust, agents: agents, home: home,
            target: ConnectorTarget(folder: home, isDefault: true, installation: installation))
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private func installed(_ rig: Rig) async throws {
        try await rig.connector.install(tool: "/opt/homebrew/bin/codex", target: rig.target)
        rig.codex.installedPath = rig.connector.pluginFolder(for: rig.home).path
    }

    @Test(arguments: [("/opt/tools/bin/codex", true), ("/Applications/Codex.app/Contents/Resources/codex", false), ("/opt/tools/bin/missing", false)])
    func theReportAndTheSearchJudgeACodexByTheSameTest(path: String, runs: Bool) throws {
        let present: Set<String> = ["/opt/tools/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        let tools = ToolEnvironment(home: "/Users/a", appEnvironment: ["PATH": "/opt/tools/bin"], shell: "/bin/zsh", isExecutable: { present.contains($0) })
        let connector = CodexConnector(agentsDir: URL(fileURLWithPath: "/tmp/agents"), pluginName: "keyscribe", tools: tools)
        #expect(connector.runs(tool: path) == runs)
        #expect(CodexInstall.runs(path, in: tools) == runs)
    }

    @Test func aCodexConversationCountsAsConnectedSinceItReportsThroughHooksRatherThanAConnection() async throws {
        let rig = try rig()
        let model = AgentsSettingsModel(
            describeTerminal: { _ in nil }, agentsDir: rig.agents, setups: ConnectorSetupRegistry(directory: rig.agents),
            connectors: [rig.connector], hosts: [CodexHost.kind])
        await model.refresh()
        let setup = try #require(model.connectors.first?.setups.first { $0.folder.path == rig.home.path })
        let thread = AgentConversation(
            id: "codex:t1@\(rig.home.path)", agent: "codex", pid: nil, cwd: "/src/app", handle: "app", state: .idle, connectorLive: false,
            host: AgentHostLocation(host: "codex", instance: rig.home.path, native: "t1"))
        model.show([thread])
        #expect(setup.usedBy == ["app"])
        #expect(setup.connectedCount == 1)
    }

    @Test func installWritesThePluginAddsItToThisCodexHomeAndAddsTheThreadIdTitleItem() async throws {
        let rig = try rig(config: "model = \"x\"\n")
        try await installed(rig)
        #expect(rig.codex.subcommands == ["plugin marketplace add", "plugin add keyscribe@keyscribe-local"])
        #expect(rig.codex.calls.allSatisfy { $0.environment["CODEX_HOME"] == rig.home.path })
        let marketplace = rig.connector.marketplaceFolder(for: rig.home)
        #expect(rig.codex.calls.first?.argv.last == marketplace.path)
        let expected = CodexPlugin.files(rig.connector.layout, executable: rig.connector.executable.path, installation: "inst-1")
        for (path, body) in expected { #expect(text(marketplace.appendingPathComponent(path)) == body) }
        #expect(CodexTitleItem.inspect(text(rig.config)) == .present)
        #expect(text(rig.config)?.hasPrefix("model = \"x\"\n") == true)
    }

    @Test func theExecutableIsWrittenOutsideThePluginRunnableWithTheAgentsFolderFilledIn() async throws {
        let rig = try rig()
        try await installed(rig)
        let script = try #require(text(rig.connector.executable))
        #expect(!script.contains("__AGENTS_DIR__"))
        #expect(!script.contains("__APP_NAME__"))
        #expect(script.contains("agents=\(ShellWord.quoted(rig.agents.path))"))
        let mode = try FileManager.default.attributesOfItem(atPath: rig.connector.executable.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(!rig.connector.executable.path.hasPrefix(rig.connector.marketplaceFolder(for: rig.home).path))
    }

    @Test func aConfigThatCannotBeReadStopsTheInstallBeforeAnythingChanges() async throws {
        let rig = try rig(config: "[tui\nbroken")
        await #expect(throws: AgentConnectorError.self) { try await rig.connector.install(tool: "/x/codex", target: rig.target) }
        #expect(rig.codex.calls.isEmpty)
        #expect(text(rig.config) == "[tui\nbroken")
        #expect(!rig.connector.hasFiles(in: rig.target))
    }

    static let trusted = "[hooks.state.\"keyscribe@keyscribe-local:plugin.json#hooks[0]:stop:0:0\"]\ntrusted_hash = \"sha256:b\"\n"

    @Test func uninstallRemovesThePluginAndOnlyTheTitleItemItAddedLeavingTheConfigAsItWas() async throws {
        let original = "[tui]\nterminal_title = [\"project-name\", \"git-branch\"]\n\n[hooks.state.\"other@x:hooks[0]:stop:0:0\"]\ntrusted_hash = \"a\"\n"
        let rig = try rig(config: original)
        try await installed(rig)
        #expect(text(rig.config) != original)
        try Data(((text(rig.config) ?? "") + Self.trusted).utf8).write(to: rig.config)
        try await rig.connector.uninstall(tool: "/x/codex", target: rig.target)
        #expect(text(rig.config) == original)
        #expect(rig.codex.subcommands.suffix(2) == ["plugin remove keyscribe@keyscribe-local", "plugin marketplace remove"])
        #expect(!FileManager.default.fileExists(atPath: rig.connector.marketplaceFolder(for: rig.home).path))
    }

    @Test func anUninstallThatCannotTakeItsTitleItemBackFailsAndKeepsWhatARetryNeeds() async throws {
        let rig = try rig(config: "[tui]\nterminal_title = [\"project-name\"]\n")
        try await installed(rig)
        try Data("[tui\nbroken".utf8).write(to: rig.config)
        await #expect(throws: AgentConnectorError.self) { try await rig.connector.uninstall(tool: "/x/codex", target: rig.target) }
        #expect(text(rig.config) == "[tui\nbroken")
        #expect(rig.connector.hasFiles(in: rig.target))
    }

    @Test func anUpdateOverAMarketplaceCodexAlreadyHasSucceeds() async throws {
        let rig = try rig(config: "[tui]\nterminal_title = [\"project-name\"]\n")
        try await installed(rig)
        let folder = rig.connector.marketplaceFolder(for: rig.home).path
        let config = (text(rig.config) ?? "") + "\n[marketplaces.keyscribe-local]\nsource_type = \"local\"\nsource = \"\(folder)\"\n"
        try Data(config.utf8).write(to: rig.config)
        rig.codex.answer("plugin marketplace add", status: 1, stderr: "marketplace 'keyscribe-local' already exists")
        try await rig.connector.update(tool: "/x/codex", target: rig.target)
        rig.codex.answer("plugin marketplace add", status: 1, stderr: "no such folder")
        try Data("[tui]\nterminal_title = [\"project-name\", \"thread-id\"]\n".utf8).write(to: rig.config)
        await #expect(throws: AgentConnectorError.self) { try await rig.connector.update(tool: "/x/codex", target: rig.target) }
    }

    @Test func anUninstallCodexAlreadyFinishedSucceedsAndOneItCouldNotDoFails() async throws {
        let rig = try rig(config: "[tui]\nterminal_title = [\"project-name\"]\n")
        try await installed(rig)
        rig.codex.answer("plugin remove", status: 1, stderr: "not installed")
        rig.codex.answer("plugin marketplace remove", status: 1, stderr: "not found")
        try await rig.connector.uninstall(tool: "/x/codex", target: rig.target)
        #expect(!rig.connector.hasFiles(in: rig.target))
        let again = try self.rig(config: "[tui]\nterminal_title = [\"project-name\"]\n")
        try await installed(again)
        let config = (text(again.config) ?? "") + "\n[plugins.\"keyscribe@keyscribe-local\"]\nenabled = true\n"
        try Data(config.utf8).write(to: again.config)
        again.codex.answer("plugin remove", status: 1, stderr: "permission denied")
        await #expect(throws: AgentConnectorError.self) { try await again.connector.uninstall(tool: "/x/codex", target: again.target) }
        #expect(again.connector.hasFiles(in: again.target))
    }

    @Test func anAppNameTheShellWouldReadIsWrittenIntoTheExecutableAsPlainText() throws {
        let name = #"Ac"me $(touch /tmp/ks-never) `x` \ App"#
        let filled = CodexConnector.filled("app=__APP_NAME__\nprintf '%s' \"$app\"\n", agentsDir: URL(fileURLWithPath: "/tmp/a"), app: name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", filled]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(try JSONDecoder().decode(String.self, from: Data("\"\(printed)\"".utf8)) == name)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/ks-never"))
    }

    @Test func anUninstallAfterTheUserDeletedTheConfigLeavesItDeleted() async throws {
        let rig = try rig(config: "[tui]\nterminal_title = [\"project-name\"]\n")
        try await installed(rig)
        try FileManager.default.removeItem(at: rig.config)
        try await rig.connector.uninstall(tool: "/x/codex", target: rig.target)
        #expect(!FileManager.default.fileExists(atPath: rig.config.path))
    }

    @Test func uninstallingWithoutCodexTakesOurTitleItemBackBeforeTheFolderHoldingItsRecordIsDeleted() async throws {
        let original = "[tui]\nterminal_title = [\"project-name\"]\n"
        let rig = try rig(config: original)
        try await installed(rig)
        try Data(((text(rig.config) ?? "") + Self.trusted).utf8).write(to: rig.config)
        try await rig.connector.uninstallWithoutTool(target: rig.target)
        #expect(text(rig.config) == original)
        #expect(rig.connector.manualUninstall(for: rig.target).count == 3)
        let again = try self.rig(config: original)
        try await installed(again)
        try Data("[tui\nbroken".utf8).write(to: again.config)
        await #expect(throws: AgentConnectorError.self) { try await again.connector.uninstallWithoutTool(target: again.target) }
    }

    @Test func anUninstallWithoutCodexThatCannotTakeItsItemBackLeavesTheSetupAsItWas() async throws {
        let original = "[tui]\nterminal_title = [\"project-name\"]\n"
        let rig = try rig(config: original)
        let registry = ConnectorSetupRegistry(directory: rig.agents)
        func connector(finding: Bool) -> CodexConnector {
            CodexConnector(
                agentsDir: rig.agents, pluginName: "keyscribe", home: rig.home.deletingLastPathComponent(),
                script: "#!/bin/sh\nagents=__AGENTS_DIR__\napp=__APP_NAME__\n",
                run: { argv, subcommand, _, environment in rig.codex.run(argv, subcommand, environment) },
                tools: ToolEnvironment(
                    appEnvironment: ["PATH": "/test-bin"], shell: "/bin/zsh",
                    execute: { _, _, _, _, _ in ToolCLI.Ran(end: .exited(0), output: Data("codex-cli 0.170.0".utf8)) },
                    isExecutable: { finding && $0 == "/test-bin/codex" }),
                trust: { _, _ in .trusted })
        }
        let found = AgentsSettingsModel(
            describeTerminal: { _ in nil }, agentsDir: rig.agents, setups: registry, connectors: [connector(finding: true)], hosts: [CodexHost.kind])
        await found.refresh()
        let installing = try #require(found.connectors[0].setups.first { $0.folder.path == rig.home.path })
        await installing.install()
        rig.codex.installedPath = rig.connector.pluginFolder(for: rig.home).path
        let installation = try #require(installing.target.installation)
        try Data("[tui\nbroken".utf8).write(to: rig.config)
        let missing = AgentsSettingsModel(
            describeTerminal: { _ in nil }, agentsDir: rig.agents, setups: ConnectorSetupRegistry(directory: rig.agents),
            connectors: [connector(finding: false)], hosts: [CodexHost.kind])
        await missing.refresh()
        let setup = try #require(missing.connectors[0].setups.first { $0.folder.path == rig.home.path })
        #expect(setup.canUninstallWithoutTool)
        await setup.remove()
        #expect(setup.state == .failed(CodexConnector.titleNotRemoved))
        await setup.refresh()
        #expect(setup.manualUninstall.isEmpty)
        #expect(setup.target.installation == installation && !setup.target.removing)
        #expect(FileManager.default.fileExists(atPath: rig.connector.marketplaceFolder(for: rig.home).appendingPathComponent("title-item.json").path))
    }

    @Test func aConfigThatCannotBeReadKeepsTheRecordUninstallNeeds() async throws {
        let rig = try rig(config: "[tui]\nterminal_title = [\"project-name\"]\n")
        try await installed(rig)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.config.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rig.config.path) }
        await #expect(throws: AgentConnectorError.self) { try await rig.connector.uninstallWithoutTool(target: rig.target) }
        await #expect(throws: AgentConnectorError.self) { try await rig.connector.uninstall(tool: "/x/codex", target: rig.target) }
        #expect(FileManager.default.fileExists(atPath: rig.connector.marketplaceFolder(for: rig.home).appendingPathComponent("title-item.json").path))
    }

    @Test func aConfigThatCannotBeReadIsNeverReplacedByAnInstall() async throws {
        let original = "[tui]\nterminal_title = [\"project-name\"]\n"
        let rig = try rig(config: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.config.path)
        await #expect(throws: AgentConnectorError.self) { try await rig.connector.install(tool: "/x/codex", target: rig.target) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rig.config.path)
        #expect(text(rig.config) == original)
    }

    @Test func aTitleItemTheUserAlreadyHadIsKeptOnUninstall() async throws {
        let original = "[tui]\nterminal_title = [\"thread-id\"]\n"
        let rig = try rig(config: original)
        try await installed(rig)
        try await rig.connector.uninstall(tool: "/x/codex", target: rig.target)
        #expect(text(rig.config) == original)
    }

    @Test func aReadyConnectorIsInstalledTrustedAndShowsTheThreadId() async throws {
        let rig = try rig()
        try await installed(rig)
        #expect(await rig.connector.check(tool: "/x/codex", target: rig.target) == .status(.ready))
    }

    @Test func hooksAwaitingTrustSayWhereToTrustThem() async throws {
        let rig = try rig()
        try await installed(rig)
        rig.trust.result = .needsTrust
        guard case .broken(let why) = await rig.connector.check(tool: "/x/codex", target: rig.target) else {
            Issue.record("not broken")
            return
        }
        #expect(why.contains("/hooks"))
    }

    @Test func aTitleItemRemovedByHandNeedsRepairAndCheckingNeverPutsItBack() async throws {
        let rig = try rig()
        try await installed(rig)
        try Data("[tui]\nterminal_title = [\"project-name\"]\n".utf8).write(to: rig.config)
        guard case .broken(let why) = await rig.connector.check(tool: "/x/codex", target: rig.target) else {
            Issue.record("not broken")
            return
        }
        #expect(why.contains("thread-id"))
        #expect(text(rig.config) == "[tui]\nterminal_title = [\"project-name\"]\n")
        try await rig.connector.update(tool: "/x/codex", target: rig.target)
        #expect(CodexTitleItem.inspect(text(rig.config)) == .present)
    }

    @Test func aPluginCodexListsAsOffOrMissingIsReportedSo() async throws {
        let rig = try rig()
        try await installed(rig)
        rig.codex.enabled = false
        #expect(await rig.connector.check(tool: "/x/codex", target: rig.target) == .status(.disabled))
        rig.codex.installedPath = "/elsewhere"
        #expect(await rig.connector.check(tool: "/x/codex", target: rig.target) == .status(.notInstalled))
        rig.codex.answer("plugin list", status: 1, stderr: "boom")
        #expect(await rig.connector.check(tool: "/x/codex", target: rig.target) == .status(.unknown))
    }

    @Test func aDaemonThatCannotSayWhetherHooksAreTrustedLeavesTheConnectorReady() async throws {
        let rig = try rig()
        try await installed(rig)
        rig.trust.result = nil
        #expect(await rig.connector.check(tool: "/x/codex", target: rig.target) == .status(.ready))
    }

    @Test func anAppServerThatListsNoneOfOurHooksSaysSo() async throws {
        let rig = try rig()
        try await installed(rig)
        rig.trust.result = .absent
        #expect(await rig.connector.check(tool: "/x/codex", target: rig.target) == .broken(CodexConnector.hooksNotListed))
    }

    @Test func nothingInstalledIsNotInstalledAndAHalfRemovedSetupIsUnfinished() async throws {
        let rig = try rig()
        #expect(await rig.connector.check(tool: "/x/codex", target: rig.target) == .status(.notInstalled))
        try await installed(rig)
        var removing = rig.target
        removing.removing = true
        #expect(await rig.connector.check(tool: "/x/codex", target: removing) == .removalUnfinished(nil))
    }

    @Test func aChangedInstallationIsOutdatedUntilUpdated() async throws {
        let rig = try rig()
        try await installed(rig)
        var moved = rig.target
        moved.installation = "inst-2"
        guard case .status(.outdated) = await rig.connector.check(tool: "/x/codex", target: moved) else {
            Issue.record("not outdated")
            return
        }
    }

    @Test func eachCodexHomeGetsItsOwnMarketplaceFolder() throws {
        let rig = try rig()
        let other = rig.home.deletingLastPathComponent().appendingPathComponent(".codex-work")
        #expect(rig.connector.marketplaceFolder(for: rig.home) != rig.connector.marketplaceFolder(for: other))
        #expect(rig.connector.folderVariable == "CODEX_HOME")
    }

    @Test func aFolderIsACodexHomeWhenItHoldsCodexsConfigOrLogin() throws {
        let rig = try rig(config: "")
        #expect(rig.connector.recognizes(folder: rig.home))
        #expect(!rig.connector.recognizes(folder: rig.agents))
    }
}
