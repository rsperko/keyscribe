import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct BBPluginConnectorTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [([String], [String: String])] = []
        private var answers: [String: HostCLI.Output] = [:]
        func record(_ argv: [String], _ environment: [String: String]) { lock.withLock { made.append((argv, environment)) } }
        var all: [([String], [String: String])] { lock.withLock { made } }
        func set(_ subcommand: String, status: Int32 = 0, _ stdout: String, stderr: String = "") {
            lock.withLock { answers[subcommand] = HostCLI.Output(status: status, stdout: Data(stdout.utf8), stderr: stderr, truncated: false) }
        }
        func answer(_ subcommand: String) -> HostCLI.Output {
            lock.withLock { answers[subcommand] } ?? HostCLI.Output(status: 0, stdout: Data(#"{"ok":true,"plugins":[]}"#.utf8), stderr: "", truncated: false)
        }
    }

    static let sources = [
        "package.json": #"{"name":"bb-plugin-keyscribe","bb":{"name":"Placeholder","server":"./server.ts"}}"#, "server.ts": "s",
        "keyscribe.ts": "k", "PLUGIN_OVERVIEW.md": "o",
    ]

    private func scratch() -> (home: URL, agents: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ks-bbplugin-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".bb/bin"), withIntermediateDirectories: true)
        return (home, root.appendingPathComponent("agents", isDirectory: true))
    }

    private func connector(_ home: URL, _ agents: URL, calls: Calls, id: String = "keyscribe-dev", sources: [String: String]? = Self.sources) -> BBPluginConnector {
        BBPluginConnector(
            agentsDir: agents, pluginName: id, home: home, sources: sources, isExecutable: { _ in true },
            run: { argv, subcommand, _, environment in
                calls.record(argv, environment)
                return calls.answer(subcommand)
            })
    }

    private func target(_ home: URL, installation: String? = "inst-bb", removing: Bool = false) -> ConnectorTarget {
        ConnectorTarget(folder: home.appendingPathComponent(".bb", isDirectory: true), isDefault: true, installation: installation, removing: removing)
    }

    private func listing(_ agents: URL, id: String = "keyscribe-dev", enabled: Bool = true, status: String = "running", detail: String? = nil, source: String? = nil) -> String {
        let source = source ?? "path:" + agents.appendingPathComponent("bb-plugin").path
        let detailJSON = detail.map { "\"\($0)\"" } ?? "null"
        return #"{"plugins":[{"id":"other","enabled":true,"status":"running","source":"builtin:other"},{"id":"\#(id)","enabled":\#(enabled),"status":"\#(status)","statusDetail":\#(detailJSON),"source":"\#(source)"}]}"#
    }

    @Test func installingWritesThePluginUnderThisAppsOwnIdAndHasBbInstallItFromThatFolder() async throws {
        let (home, agents) = scratch()
        let calls = Calls()
        let plugin = connector(home, agents, calls: calls)
        let tool = try #require(plugin.locateTool())
        #expect(tool == home.appendingPathComponent(".bb/bin/bb").path)
        try await plugin.install(tool: tool, target: target(home))
        let folder = agents.appendingPathComponent("bb-plugin")
        #expect(try String(contentsOf: folder.appendingPathComponent("server.ts"), encoding: .utf8) == "s")
        #expect(try String(contentsOf: folder.appendingPathComponent("keyscribe.ts"), encoding: .utf8) == "k")
        #expect(try String(contentsOf: folder.appendingPathComponent("PLUGIN_OVERVIEW.md"), encoding: .utf8) == "o")
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("package.json"))) as? [String: Any])
        #expect(manifest["name"] as? String == "bb-plugin-keyscribe-dev")
        #expect((manifest["bb"] as? [String: Any])?["name"] as? String == Branding.appName)
        let config = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("keyscribe.json"))) as? [String: Any])
        #expect(config["installation"] as? String == "inst-bb")
        #expect(config["instance"] as? String == home.appendingPathComponent(".bb").path)
        #expect(config["socketPath"] as? String == agents.appendingPathComponent("bridge.sock").path)
        #expect(config["tokenPath"] as? String == agents.appendingPathComponent("token").path)
        #expect(config["readyPath"] as? String == agents.appendingPathComponent("ready.json").path)
        #expect(config["protocol"] as? Int == AgentBridgeCodec.protocolVersion)
        #expect(config["version"] as? String == plugin.bundledVersion)
        #expect(calls.all.map(\.0) == [[tool, "plugin", "list", "--json"], [tool, "plugin", "install", folder.path, "--yes", "--json"]])
        for (_, environment) in calls.all {
            #expect(environment["BB_TELEMETRY"] == "false")
            #expect(environment["BB_DATA_DIR"] == home.appendingPathComponent(".bb").path)
        }
        calls.set("plugin list", listing(agents))
        #expect(await plugin.check(tool: tool, target: target(home)) == .status(.ready))
    }

    @Test func updatingRewritesTheFilesAndHasBbReloadThePluginItAlreadyRuns() async throws {
        let (home, agents) = scratch()
        let calls = Calls()
        calls.set("plugin list", listing(agents))
        let plugin = connector(home, agents, calls: calls)
        let tool = try #require(plugin.locateTool())
        try await plugin.update(tool: tool, target: target(home))
        #expect(calls.all.map { Array($0.0.dropFirst()) } == [["plugin", "list", "--json"], ["plugin", "reload", "keyscribe-dev", "--json"]])
    }

    @Test func bbRefusingTheInstallSaysWhyInItsOwnWords() async throws {
        let (home, agents) = scratch()
        let calls = Calls()
        calls.set("plugin install", status: 1, #"{"ok":false,"error":{"code":"server_unavailable","message":"bb is not running"}}"#)
        let plugin = connector(home, agents, calls: calls)
        do {
            try await plugin.install(tool: plugin.locateTool()!, target: target(home))
            Issue.record("expected the install to fail")
        } catch let error as AgentConnectorError {
            #expect(error.message == "bb is not running")
        }
    }

    @Test func installedIsWhatBbReportsForThisAppsCopyOfThePlugin() async throws {
        let (home, agents) = scratch()
        let calls = Calls()
        let plugin = connector(home, agents, calls: calls)
        let tool = try #require(plugin.locateTool())
        #expect(await plugin.check(tool: tool, target: target(home)) == .status(.notInstalled))
        #expect(calls.all.isEmpty)
        try await plugin.install(tool: tool, target: target(home))
        calls.set("plugin list", #"{"plugins":[]}"#)
        #expect(await plugin.check(tool: tool, target: target(home)) == .status(.notInstalled))
        calls.set("plugin list", listing(agents, source: "path:/elsewhere/bb-plugin"))
        #expect(await plugin.check(tool: tool, target: target(home)) == .status(.notInstalled))
        calls.set("plugin list", listing(agents, enabled: false, status: "disabled"))
        #expect(await plugin.check(tool: tool, target: target(home)) == .status(.disabled))
        calls.set("plugin list", listing(agents, status: "error", detail: "SyntaxError"))
        #expect(await plugin.check(tool: tool, target: target(home)) == .broken("bb reports the plugin as error: SyntaxError"))
        calls.set("plugin list", listing(agents, detail: "no failures yet"))
        #expect(await plugin.check(tool: tool, target: target(home)) == .status(.ready))
        calls.set("plugin list", listing(agents, detail: "reload failed: SyntaxError"))
        #expect(await plugin.check(tool: tool, target: target(home)) == .broken("bb kept the plugin\u{2019}s earlier version running: reload failed: SyntaxError"))
        calls.set("plugin list", status: 1, #"{"ok":false,"error":{"code":"server_unavailable","message":"bb is not running"}}"#)
        #expect(await plugin.check(tool: tool, target: target(home)) == .status(.unknown))
    }

    @Test func thePluginReadsAsOutdatedWhenItsFilesOrItsInstallationDifferFromThisApp() async throws {
        let (home, agents) = scratch()
        let calls = Calls()
        let plugin = connector(home, agents, calls: calls)
        let tool = try #require(plugin.locateTool())
        try await plugin.install(tool: tool, target: target(home))
        calls.set("plugin list", listing(agents))
        #expect(await plugin.check(tool: tool, target: target(home, installation: "other")) == .status(.outdated(installed: plugin.bundledVersion!)))
        let newer = connector(home, agents, calls: calls, sources: Self.sources.merging(["keyscribe.ts": "k2"]) { $1 })
        #expect(await newer.check(tool: tool, target: target(home)) == .status(.outdated(installed: plugin.bundledVersion!)))
        #expect(await plugin.check(tool: tool, target: target(home, removing: true)) == .removalUnfinished(nil))
    }

    @Test func eachCopyOfTheAppInstallsItsOwnPlugin() async throws {
        let (home, agents) = scratch()
        let calls = Calls()
        let plugin = connector(home, agents, calls: calls, id: "keyscribe")
        try await plugin.install(tool: plugin.locateTool()!, target: target(home))
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: agents.appendingPathComponent("bb-plugin/package.json"))) as? [String: Any])
        #expect(manifest["name"] as? String == "bb-plugin-keyscribe")
        calls.set("plugin list", listing(agents, id: "keyscribe-dev"))
        #expect(await plugin.check(tool: plugin.locateTool()!, target: target(home)) == .status(.notInstalled))
    }

    @Test func uninstallingRemovesThePluginFromBbAndDeletesItsFolder() async throws {
        let (home, agents) = scratch()
        let calls = Calls()
        let plugin = connector(home, agents, calls: calls)
        let tool = try #require(plugin.locateTool())
        try await plugin.install(tool: tool, target: target(home))
        try await plugin.uninstall(tool: tool, target: target(home, removing: true))
        #expect(calls.all.last?.0 == [tool, "plugin", "remove", "keyscribe-dev", "--json"])
        #expect(!plugin.hasFiles(in: target(home)))
        #expect(await plugin.check(tool: tool, target: target(home, removing: true)) == .status(.notInstalled))
    }

    @Test func aPluginBbAlreadyForgotStillUninstalls() async throws {
        let (home, agents) = scratch()
        let calls = Calls()
        let plugin = connector(home, agents, calls: calls)
        let tool = try #require(plugin.locateTool())
        try await plugin.install(tool: tool, target: target(home))
        calls.set("plugin remove", status: 1, #"{"ok":false,"error":{"code":"plugin_not_found","message":"no such plugin"}}"#)
        try await plugin.uninstall(tool: tool, target: target(home, removing: true))
        #expect(!plugin.hasFiles(in: target(home)))
    }

    @Test func theAppCarriesThePluginSources() throws {
        let sources = try #require(BBPluginFiles.sources)
        #expect(Set(sources.keys) == Set(BBPluginFiles.names))
        #expect(sources["keyscribe.ts"]?.contains("export function keyscribe") == true)
    }

    @Test func withoutItsBundledFilesThePluginIsUnavailable() async {
        let (home, agents) = scratch()
        let plugin = connector(home, agents, calls: Calls(), sources: nil)
        #expect(!plugin.isBundled)
        #expect(await plugin.check(tool: "/x/bb", target: target(home)) == .unavailable)
    }
}
