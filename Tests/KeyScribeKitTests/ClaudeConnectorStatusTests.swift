import Foundation
import Testing
@testable import KeyScribeKit

struct ClaudeConnectorStatusTests {
    private let id = "keyscribe-dev@keyscribe-dev-local"

    private func list(_ entries: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: entries)
    }

    private func status(_ entries: [[String: Any]], bundled: String = "0.1.0-aaaa") -> ClaudeConnectorStatus {
        ClaudeConnectorStatus.parse(pluginList: list(entries), pluginId: id, bundledVersion: bundled)
    }

    @Test func aMissingPluginIsNotInstalled() {
        #expect(status([["id": "other@market", "version": "1", "enabled": true, "scope": "user"]]) == .notInstalled)
    }

    @Test func theCurrentVersionEnabledForTheUserIsReady() {
        #expect(status([["id": id, "version": "0.1.0-aaaa", "enabled": true, "scope": "user"]]) == .ready)
    }

    @Test func anOlderVersionNeedsAnUpdate() {
        #expect(status([["id": id, "version": "0.1.0-bbbb", "enabled": true, "scope": "user"]]) == .outdated(installed: "0.1.0-bbbb"))
    }

    @Test func aDisabledPluginSaysSo() {
        #expect(status([["id": id, "version": "0.1.0-aaaa", "enabled": false, "scope": "user"]]) == .disabled)
    }

    @Test func onlyAUserWideInstallCounts() {
        #expect(status([["id": id, "version": "0.1.0-aaaa", "enabled": true, "scope": "local", "projectPath": "/src/x"]]) == .notInstalled)
    }

    @Test func unreadableOutputIsReportedNotGuessed() {
        #expect(ClaudeConnectorStatus.parse(pluginList: Data("oops".utf8), pluginId: id, bundledVersion: "1") == .unknown)
    }
}
