import CryptoKit
import Foundation
import KeyScribeKit
import Testing

struct CodexPluginTests {
    let executable = "/Users/me/Library/Application Support/App/agents/codex/keyscribe-codex"
    var layout: CodexPlugin.Layout { CodexPlugin.Layout(plugin: "keyscribe", marketplace: "keyscribe-local", title: "App") }

    private func object(_ text: String?) -> [String: Any]? {
        text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    @Test func theMarketplaceOffersThePluginFromItsOwnFolder() throws {
        let files = CodexPlugin.files(layout, executable: executable, installation: "inst-1")
        let marketplace = try #require(object(files[".agents/plugins/marketplace.json"]))
        #expect(marketplace["name"] as? String == "keyscribe-local")
        let plugin = try #require((marketplace["plugins"] as? [[String: Any]])?.first)
        #expect(plugin["name"] as? String == "keyscribe")
        #expect((plugin["source"] as? [String: Any])?["path"] as? String == "./plugins/keyscribe")
    }

    @Test func everyHookRunsTheOneExecutableQuotedWithTheInstallationAndNothingElse() throws {
        let files = CodexPlugin.files(layout, executable: executable, installation: "inst-1")
        let manifest = try #require(object(files["plugins/keyscribe/.codex-plugin/plugin.json"]))
        #expect(manifest["name"] as? String == "keyscribe")
        #expect(manifest["mcpServers"] as? String == "./.mcp.json")
        let hooks = try #require((manifest["hooks"] as? [String: Any])?["hooks"] as? [String: [[String: Any]]])
        #expect(Set(hooks.keys) == ["UserPromptSubmit", "PermissionRequest", "PreToolUse", "Interrupt", "Stop"])
        #expect(hooks["PreToolUse"]?.first?["matcher"] as? String == "request_user_input")
        for groups in hooks.values {
            let handler = try #require((groups.first?["hooks"] as? [[String: Any]])?.first)
            #expect(handler["type"] as? String == "command")
            #expect(handler["command"] as? String == "'\(executable)' hook inst-1")
            #expect(handler["async"] == nil)
            #expect((handler["timeout"] as? Int).map { $0 <= 3 } == true)
        }
    }

    @Test func theReadAloudServerIsTheSameExecutableApprovedWithoutAsking() throws {
        let files = CodexPlugin.files(layout, executable: executable, installation: "inst-1")
        let servers = try #require(object(files["plugins/keyscribe/.mcp.json"])?["mcpServers"] as? [String: [String: Any]])
        let server = try #require(servers.values.first)
        #expect(servers.count == 1)
        #expect(server["command"] as? String == executable)
        #expect(server["args"] as? [String] == ["mcp", "inst-1"])
        #expect(server["default_tools_approval_mode"] as? String == "approve")
    }

    @Test func theFilesAreExactlyTheBytesUsersTrustedSoAChangeIsMadeOnPurpose() {
        let files = CodexPlugin.files(layout, executable: executable, installation: "inst-1")
        let joined = files.keys.sorted().map { "\($0)\n\(files[$0] ?? "")" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "075e42c7c4e2829dbe1a50634494d2533041216693655e0b2c37acf90ec9a05f", "Changing these files makes every user trust the hooks again. If that is intended, update the digest.")
        #expect(files != CodexPlugin.files(layout, executable: executable, installation: "inst-2"))
    }

    @Test func trustIsReadFromOnlyThisPluginsHooks() {
        let id = "keyscribe@keyscribe-local"
        func listing(_ hooks: [(String?, String)]) -> Data {
            let items = hooks.map { #"{"pluginId":\#($0.0.map { "\"\($0)\"" } ?? "null"),"trustStatus":"\#($0.1)","enabled":true}"# }.joined(separator: ",")
            return Data(#"{"data":[{"cwd":"/","hooks":[\#(items)],"warnings":[],"errors":[]}]}"#.utf8)
        }
        #expect(CodexPlugin.trust(listing([(id, "trusted"), (id, "trusted"), ("other@x", "untrusted"), (nil, "modified")]), pluginId: id) == .trusted)
        #expect(CodexPlugin.trust(listing([(id, "trusted"), (id, "untrusted")]), pluginId: id) == .needsTrust)
        #expect(CodexPlugin.trust(listing([(id, "modified")]), pluginId: id) == .needsTrust)
        #expect(CodexPlugin.trust(listing([(id, "managed")]), pluginId: id) == .trusted)
        #expect(CodexPlugin.trust(listing([("other@x", "trusted")]), pluginId: id) == .absent)
        #expect(CodexPlugin.trust(listing([(id, "whatever")]), pluginId: id) == .unreadable)
        #expect(CodexPlugin.trust(Data("nope".utf8), pluginId: id) == .unreadable)
    }

    @Test func theInstalledPluginIsFoundOnlyFromOurOwnFolder() {
        let id = "keyscribe@keyscribe-local"
        func listing(_ path: String, enabled: Bool = true) -> Data {
            Data(#"{"installed":[{"pluginId":"\#(id)","installed":true,"enabled":\#(enabled),"source":{"source":"local","path":"\#(path)"}}],"available":[]}"#.utf8)
        }
        #expect(CodexPlugin.installed(listing("/ours/plugins/keyscribe"), pluginId: id, path: "/ours/plugins/keyscribe") == .enabled)
        #expect(CodexPlugin.installed(listing("/ours/plugins/keyscribe", enabled: false), pluginId: id, path: "/ours/plugins/keyscribe") == .disabled)
        #expect(CodexPlugin.installed(listing("/someone/else"), pluginId: id, path: "/ours/plugins/keyscribe") == .absent)
        #expect(CodexPlugin.installed(Data(#"{"installed":[],"available":[]}"#.utf8), pluginId: id, path: "/x") == .absent)
        #expect(CodexPlugin.installed(Data("{}".utf8), pluginId: id, path: "/x") == nil)
    }
}
