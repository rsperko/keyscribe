import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandRunnerTests {
    final class FakeSystem: VoiceCommandSystem {
        var ownBundleId: String? = "com.keyscribe.app.dev"
        var running: [VoiceCommandCatalog.App] = []
        var installed: [VoiceCommandCatalog.App] = []
        var tabs: [VoiceCommandCatalog.Tab] = []
        var openSucceeds = true
        var focusResult: TabFocusResult = .focused
        var notInstalled: Set<String> = []
        var whileFocusing: () -> Void = {}
        var tabsUnreadable = false
        private(set) var opened: [String] = []
        private(set) var focused: [VoiceCommandCatalog.Tab] = []
        private(set) var openedURLs: [(String, String?)] = []
        private(set) var tabReads: [String?] = []
        private(set) var installedScans = 0

        func runningApps() -> [VoiceCommandCatalog.App] { running }
        func installedApps() async -> [VoiceCommandCatalog.App] { installedScans += 1; return installed }
        func browserTabs(in browser: String?) async -> [VoiceCommandCatalog.Tab]? {
            tabReads.append(browser)
            if tabsUnreadable { return nil }
            return tabs.filter { browser == nil || $0.browserBundleId == browser }
        }
        func appName(forBundleId bundleId: String) -> String? {
            (running + installed).first { $0.bundleId == bundleId }?.name
        }
        func isRunning(bundleId: String) -> Bool { running.contains { $0.bundleId == bundleId } }
        func isInstalled(bundleId: String) -> Bool { !notInstalled.contains(bundleId) }
        func openApp(bundleId: String) async -> Bool { opened.append(bundleId); return openSucceeds }
        func focusTab(_ tab: VoiceCommandCatalog.Tab) async -> TabFocusResult {
            focused.append(tab)
            whileFocusing()
            return focusResult
        }
        func openURL(_ url: String, browser: String?) async -> Bool { openedURLs.append((url, browser)); return openSucceeds }
    }

    private let chrome = VoiceCommandCatalog.App(name: "Google Chrome", bundleId: "com.google.Chrome")
    private let textEdit = VoiceCommandCatalog.App(name: "TextEdit", bundleId: "com.apple.TextEdit")
    private let ghostty = VoiceCommandCatalog.App(name: "Ghostty", bundleId: "com.mitchellh.ghostty")
    private let gmail = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"))

    private func make() -> (VoiceCommandRunner, FakeSystem) {
        let system = FakeSystem()
        system.running = [chrome, textEdit, ghostty]
        return (VoiceCommandRunner(system: system), system)
    }

    @Test func switchesToARunningApp() async {
        let (runner, system) = make()
        let outcome = await runner.run(transcript: "Switch to Ghostty.", places: [], origin: .init(bundleId: textEdit.bundleId))
        #expect(outcome == .done(summary: "Ghostty"))
        #expect(system.opened == [ghostty.bundleId])
        #expect(system.tabReads.isEmpty)
    }

    @Test func goBackReturnsToTheOriginAndToggles() async {
        let (runner, system) = make()
        _ = await runner.run(transcript: "switch to ghostty", places: [], origin: .init(bundleId: textEdit.bundleId))
        #expect(await runner.run(transcript: "go back", places: [], origin: .init(bundleId: ghostty.bundleId))
                == .done(summary: "TextEdit"))
        #expect(await runner.run(transcript: "go back", places: [], origin: .init(bundleId: textEdit.bundleId))
                == .done(summary: "Ghostty"))
        #expect(system.opened == [ghostty.bundleId, textEdit.bundleId, ghostty.bundleId])
    }

    @Test func goBackWithNothingToReturnToFails() async {
        let (runner, system) = make()
        #expect(await runner.run(transcript: "go back", places: [], origin: .init(bundleId: textEdit.bundleId))
                == .failed(message: "Nothing to go back to."))
        #expect(system.opened.isEmpty)
    }

    @Test func goBackToAnAppThatQuitFails() async {
        let (runner, system) = make()
        _ = await runner.run(transcript: "switch to ghostty", places: [], origin: .init(bundleId: textEdit.bundleId))
        system.running.removeAll { $0 == textEdit }
        #expect(await runner.run(transcript: "go back", places: [], origin: nil) == .failed(message: "Nothing to go back to."))
    }

    @Test func ownAppIsNeverAnOrigin() async {
        let (runner, system) = make()
        _ = await runner.run(transcript: "switch to ghostty", places: [], origin: .init(bundleId: "com.keyscribe.app.dev"))
        #expect(await runner.run(transcript: "go back", places: [], origin: nil) == .failed(message: "Nothing to go back to."))
        #expect(system.opened == [ghostty.bundleId])
    }

    @Test func aFailedCommandDoesNotMoveTheBackTarget() async {
        let (runner, system) = make()
        _ = await runner.run(transcript: "switch to ghostty", places: [], origin: .init(bundleId: textEdit.bundleId))
        _ = await runner.run(transcript: "switch to banana", places: [], origin: .init(bundleId: ghostty.bundleId))
        #expect(runner.backTarget == .init(bundleId: textEdit.bundleId))
        system.openSucceeds = false
        _ = await runner.run(transcript: "switch to chrome", places: [], origin: .init(bundleId: ghostty.bundleId))
        #expect(runner.backTarget == .init(bundleId: textEdit.bundleId))
    }

    @Test func aURLPlaceFocusesAnOpenTab() async {
        let (runner, system) = make()
        let tab = VoiceCommandCatalog.Tab(browserBundleId: chrome.bundleId, window: 1, tab: 2, url: "https://mail.google.com/mail/u/0/", title: "Inbox")
        system.tabs = [tab]
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: nil) == .done(summary: "Gmail · Google Chrome"))
        #expect(system.focused == [tab])
        #expect(system.opened == [chrome.bundleId])
        #expect(system.openedURLs.isEmpty)
    }

    @Test(arguments: [TabFocusResult.focused, .gone])
    func aCommandLostWhileTheTabIsFocusedDoesNothingMore(_ result: TabFocusResult) async {
        let (runner, system) = make()
        system.tabs = [VoiceCommandCatalog.Tab(browserBundleId: chrome.bundleId, window: 1, tab: 1, url: "https://mail.google.com/", title: "Inbox")]
        system.focusResult = result
        var wanted = true
        system.whileFocusing = { wanted = false }
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: .init(bundleId: textEdit.bundleId),
                                 stillWanted: { wanted }) == .abandoned)
        #expect(system.opened.isEmpty)
        #expect(system.openedURLs.isEmpty)
        #expect(runner.backTarget == nil)
    }

    @Test func tabRevalidationComparesAddressesCaseSensitively() throws {
        func same(_ candidate: String, _ wanted: String) throws -> Bool {
            let source = BrowserScripting.sameURLHandler
                + "return sameURL(\(BrowserScripting.literal(candidate)), \(BrowserScripting.literal(wanted)))"
            var error: NSDictionary?
            let result = try #require(NSAppleScript(source: source)?.executeAndReturnError(&error))
            #expect(error == nil)
            return result.booleanValue
        }
        #expect(try same("https://example.com/Project?View=All#Top", "https://example.com/Project?View=All#Top"))
        #expect(try !same("https://example.com/project?view=all#top", "https://example.com/Project?View=All#Top"))
    }

    @Test func theFocusScriptLeavesActivationToTheRunner() {
        let tab = VoiceCommandCatalog.Tab(browserBundleId: chrome.bundleId, window: 1, tab: 1, url: "https://mail.google.com/", title: "")
        let source = BrowserScripting.focusSource(tab, selecting: "set active tab index of window w to t")
        #expect(!source.contains("activate"))
        #expect(source.hasPrefix(BrowserScripting.sameURLHandler))
    }

    @Test func aURLPlaceOpensWhenNoTabMatches() async {
        let (runner, system) = make()
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: nil) == .done(summary: "Gmail"))
        #expect(system.openedURLs.map(\.0) == ["https://mail.google.com/"])
    }

    @Test func aTabThatCannotBeFocusedFallsBackToOpening() async {
        let (runner, system) = make()
        system.tabs = [VoiceCommandCatalog.Tab(browserBundleId: chrome.bundleId, window: 1, tab: 1, url: "https://mail.google.com/", title: "Inbox")]
        system.focusResult = .gone
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: nil) == .done(summary: "Gmail · Google Chrome"))
        #expect(system.openedURLs.map(\.0) == ["https://mail.google.com/"])
    }

    @Test func aBrowserThatDoesNotAnswerGetsNoCompetingOpen() async {
        let (runner, system) = make()
        system.tabs = [VoiceCommandCatalog.Tab(browserBundleId: chrome.bundleId, window: 1, tab: 1, url: "https://mail.google.com/", title: "Inbox")]
        system.focusResult = .noResponse
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: .init(bundleId: textEdit.bundleId))
                == .failed(message: "Google Chrome did not respond, so Gmail was not opened again."))
        #expect(system.openedURLs.isEmpty)
        #expect(runner.backTarget == nil)
    }

    @Test func tabsThatCouldNotBeReadOpenNothing() async {
        let (runner, system) = make()
        system.tabsUnreadable = true
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: nil)
                == .failed(message: "The browser did not answer in time, so nothing was opened."))
        #expect(system.openedURLs.isEmpty)
    }

    @Test func installedAppsIncludeOneLevelOfAppFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func makeApp(_ path: String, id: String) throws {
            let contents = root.appendingPathComponent(path).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: NSDictionary = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try makeApp("Top.app", id: "test.top")
        try makeApp("Developer Tools/Nested.app", id: "test.nested")
        try makeApp("Developer Tools/Deeper/TooDeep.app", id: "test.deep")
        try makeApp("Top.app/Contents/Helpers/Helper.app", id: "test.helper")
        let found = LiveVoiceCommandSystem.scanInstalledApps(in: [root], excluding: nil)
        #expect(found.map(\.bundleId) == ["test.nested", "test.top"])
    }

    @Test func aBrowserScopedPlaceReadsOnlyThatBrowser() async {
        let (runner, system) = make()
        let safariMail = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"), browser: "com.apple.Safari")
        _ = await runner.run(transcript: "switch to gmail", places: [safariMail], origin: nil)
        #expect(system.tabReads == ["com.apple.Safari"])
    }

    @Test func aChosenBrowserThatIsMissingIsNeverSwappedForAnother() async {
        let (runner, system) = make()
        let safariMail = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"), browser: "com.apple.Safari")
        system.notInstalled = ["com.apple.Safari"]
        #expect(await runner.run(transcript: "switch to gmail", places: [safariMail], origin: nil)
                == .failed(message: "The browser chosen for Gmail is not installed."))
        #expect(system.openedURLs.isEmpty)
    }

    @Test func aCommandNoLongerWantedRunsNothing() async {
        let (runner, system) = make()
        #expect(await runner.run(transcript: "switch to ghostty", places: [], origin: nil, stillWanted: { false }) == .abandoned)
        #expect(system.opened.isEmpty)
    }

    @Test func phrasesTheGrammarSettlesNeverScanInstalledApps() async {
        let (runner, system) = make()
        _ = await runner.run(transcript: "hello", places: [], origin: nil)
        _ = await runner.run(transcript: "go back", places: [], origin: nil)
        #expect(system.installedScans == 0)
    }

    @Test func failuresExplainThemselves() async {
        let (runner, _) = make()
        #expect(await runner.run(transcript: "hello", places: [], origin: nil)
                == .failed(message: "Not a command. Say \u{201C}switch to\u{201D} an app or place, or \u{201C}go back\u{201D}."))
        #expect(await runner.run(transcript: "switch to banana", places: [], origin: nil)
                == .failed(message: "No app or place called \u{201C}banana\u{201D}."))
    }

    @Test func anAppThatWillNotOpenFails() async {
        let (runner, system) = make()
        system.openSucceeds = false
        #expect(await runner.run(transcript: "switch to chrome", places: [], origin: nil)
                == .failed(message: "Could not switch to Google Chrome."))
    }
}
