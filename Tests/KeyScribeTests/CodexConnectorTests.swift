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

    @Test func uninstallRemovesThePluginAndOnlyTheTitleItemItAddedLeavingTheConfigAsItWas() async throws {
        let original = "[tui]\nterminal_title = [\"project-name\", \"git-branch\"]\n\n[hooks.state.\"other@x:hooks[0]:stop:0:0\"]\ntrusted_hash = \"a\"\n"
        let rig = try rig(config: original)
        try await installed(rig)
        #expect(text(rig.config) != original)
        try await rig.connector.uninstall(tool: "/x/codex", target: rig.target)
        #expect(text(rig.config) == original)
        #expect(rig.codex.subcommands.suffix(2) == ["plugin remove keyscribe@keyscribe-local", "plugin marketplace remove"])
        #expect(!FileManager.default.fileExists(atPath: rig.connector.marketplaceFolder(for: rig.home).path))
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
