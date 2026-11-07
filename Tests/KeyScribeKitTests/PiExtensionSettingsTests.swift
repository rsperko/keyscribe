import Foundation
import Testing
@testable import KeyScribeKit

struct PiExtensionSettingsTests {
    let plugin = "/Users/a/.pi/agent/extensions/keyscribe"
    let setup = "/Users/a/.pi/agent"
    let home = "/Users/a"

    private func excludes(_ entries: [String]) -> Bool {
        PiExtensionSettings.excludes(entries, pluginDir: plugin, setupFolder: setup, home: home)
    }

    @Test func anExactExclusionOfTheConnectorTurnsItOffHoweverItsPathIsWritten() {
        #expect(excludes(["-extensions/keyscribe"]))
        #expect(excludes(["-extensions/keyscribe/"]))
        #expect(excludes(["-extensions/keyscribe/index.ts"]))
        #expect(excludes(["-~/.pi/agent/extensions/keyscribe"]))
        #expect(excludes(["-/Users/a/.pi/agent/extensions/keyscribe"]))
        #expect(excludes(["-./extensions/../extensions/keyscribe"]))
    }

    @Test func aGlobExclusionThatMatchesTheConnectorTurnsItOff() {
        #expect(excludes(["!extensions/*"]))
        #expect(excludes(["!extensions/key*"]))
        #expect(!excludes(["!extensions/other*"]))
    }

    @Test func otherEntriesAndAnExactInclusionLeaveItOn() {
        #expect(!excludes([]))
        #expect(!excludes(["extensions/keyscribe", "-extensions/other", "-builtin:mcp"]))
        #expect(!excludes(["-extensions/keyscribe-dev"]))
        #expect(!excludes(["!extensions/*", "+extensions/keyscribe"]))
    }

    @Test func anExactExclusionWinsOverAnExactInclusionAsPiAppliesThem() {
        #expect(excludes(["+extensions/keyscribe", "-extensions/keyscribe"]))
        #expect(excludes(["!extensions/*", "+extensions/keyscribe", "-extensions/keyscribe/index.ts"]))
    }
}
