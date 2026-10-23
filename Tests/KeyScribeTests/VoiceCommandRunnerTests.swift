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
        var refused: [String] = []
        var unavailable: [String] = []
        var defaultBrowsers: [String: String] = ["https": "com.google.Chrome"]
        private(set) var defaultBrowserQueries: [String] = []
        private(set) var opened: [String] = []
        private(set) var focused: [VoiceCommandCatalog.Tab] = []
        private(set) var openedURLs: [(String, String?)] = []
        private(set) var tabReads: [String?] = []
        private(set) var installedScans = 0
        var scriptResult: ScriptRun = .finished(status: 0, lastError: nil)
        private(set) var scriptRuns: [(program: String, arguments: [String])] = []
        private(set) var shortcutRuns: [(target: String, input: String?)] = []
        private(set) var finishLate: (@MainActor (ScriptRun) -> Void)?

        func runningApps() -> [VoiceCommandCatalog.App] { running }
        func installedApps() async -> [VoiceCommandCatalog.App] { installedScans += 1; return installed }
        var whileReadingTabs: (() async -> Void)?
        func browserTabs(in browser: String?) async -> TabRead? {
            tabReads.append(browser)
            await whileReadingTabs?()
            if tabsUnreadable { return nil }
            return TabRead(tabs: tabs.filter { browser == nil || $0.browserBundleId == browser },
                           refused: refused.filter { browser == nil || $0 == browser },
                           unavailable: unavailable.filter { browser == nil || $0 == browser })
        }
        func defaultBrowserId(for url: String) -> String? {
            defaultBrowserQueries.append(url)
            return URL(string: url)?.scheme.flatMap { defaultBrowsers[$0] }
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
        var windowScan: VoiceCommandCatalog.WindowScan = .complete([])
        var windowFocusResults: [WindowFocusResult] = []
        var whileFocusingWindow: () -> Void = {}
        var runningPids: [Int32: String] = [:]
        private(set) var windowReads = 0
        private(set) var focusedWindows: [VoiceCommandCatalog.Window] = []
        private(set) var activatedPids: [Int32] = []
        func windows() async -> VoiceCommandCatalog.WindowScan { windowReads += 1; return windowScan }
        func focusWindow(_ window: VoiceCommandCatalog.Window, stillWanted: @MainActor () -> Bool) async -> WindowFocusResult {
            focusedWindows.append(window)
            whileFocusingWindow()
            guard stillWanted() else { return .cancelled }
            return windowFocusResults.isEmpty ? .focused : windowFocusResults.removeFirst()
        }
        func isRunning(pid: Int32, bundleId: String) -> Bool { runningPids[pid] == bundleId }
        func activate(pid: Int32) -> Bool { activatedPids.append(pid); return openSucceeds }
        func runScript(
            _ script: VoiceCommandScript, arguments: [String], onLateFinish: @escaping @MainActor (ScriptRun) -> Void
        ) async -> ScriptRun {
            if let shortcut = script.shortcut {
                shortcutRuns.append((shortcut.target, arguments.first))
            } else {
                scriptRuns.append((script.program, arguments))
            }
            finishLate = onLateFinish
            return scriptResult
        }
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
        #expect(outcome == .done(summary: "Ghostty", command: "Brings Ghostty to the front, opening it if needed."))
        #expect(system.opened == [ghostty.bundleId])
        #expect(system.tabReads.isEmpty)
    }

    @Test func goBackReturnsToTheOriginAndToggles() async {
        let (runner, system) = make()
        _ = await runner.run(transcript: "switch to ghostty", places: [], origin: .init(bundleId: textEdit.bundleId))
        #expect(await runner.run(transcript: "go back", places: [], origin: .init(bundleId: ghostty.bundleId))
                == .done(summary: "TextEdit", command: "Returns to TextEdit."))
        #expect(await runner.run(transcript: "go back", places: [], origin: .init(bundleId: textEdit.bundleId))
                == .done(summary: "Ghostty", command: "Returns to Ghostty."))
        #expect(system.opened == [ghostty.bundleId, textEdit.bundleId, ghostty.bundleId])
    }

    @Test func goBackToAWindowOnAnotherDesktopFailsAndKeepsItsDestination() async {
        let (runner, system) = make()
        let origin = VoiceCommandOrigin(bundleId: textEdit.bundleId, pid: 42, windowId: "cg:7")
        system.runningPids = [42: textEdit.bundleId]
        _ = await runner.run(transcript: "switch to ghostty", places: [], origin: origin)
        system.windowFocusResults = [.elsewhere]
        #expect(await runner.run(transcript: "go back", places: [], origin: .init(bundleId: ghostty.bundleId))
                == .failed(message: VoiceCommandRunner.windowElsewhereMessage, command: "Returns to TextEdit."))
        #expect(system.activatedPids.isEmpty)
        #expect(runner.backTarget == origin)
    }

    @Test func repeatingACommandForTheFrontAppKeepsTheEarlierReturnDestination() async {
        let (runner, _) = make()
        _ = await runner.run(transcript: "switch to ghostty", places: [], origin: .init(bundleId: textEdit.bundleId))
        _ = await runner.run(transcript: "switch to ghostty", places: [], origin: .init(bundleId: ghostty.bundleId))
        #expect(await runner.run(transcript: "go back", places: [], origin: .init(bundleId: ghostty.bundleId))
                == .done(summary: "TextEdit", command: "Returns to TextEdit."))
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
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: nil) == .done(summary: "Gmail · Google Chrome", command: "Focuses the open tab \u{201C}Inbox\u{201D} in Google Chrome."))
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
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: nil) == .done(summary: "Gmail", command: "No open tab matches, so it opens https://mail.google.com/."))
        #expect(system.openedURLs.map(\.0) == ["https://mail.google.com/"])
    }

    @Test func aTabThatCannotBeFocusedFallsBackToOpening() async {
        let (runner, system) = make()
        system.tabs = [VoiceCommandCatalog.Tab(browserBundleId: chrome.bundleId, window: 1, tab: 1, url: "https://mail.google.com/", title: "Inbox")]
        system.focusResult = .gone
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: nil)
                == .done(summary: "Gmail · Google Chrome", command: "No open tab matches, so it opens https://mail.google.com/."))
        #expect(system.openedURLs.map(\.0) == ["https://mail.google.com/"])
    }

    @Test func aBrowserThatDoesNotAnswerGetsNoCompetingOpen() async {
        let (runner, system) = make()
        system.tabs = [VoiceCommandCatalog.Tab(browserBundleId: chrome.bundleId, window: 1, tab: 1, url: "https://mail.google.com/", title: "Inbox")]
        system.focusResult = .noResponse
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: .init(bundleId: textEdit.bundleId))
                == .failed(message: "Google Chrome did not respond, so Gmail was not opened again.",
                           command: "Focuses the open tab \u{201C}Inbox\u{201D} in Google Chrome."))
        #expect(system.openedURLs.isEmpty)
        #expect(runner.backTarget == nil)
    }

    @Test func tabsThatCouldNotBeReadOpenNothing() async {
        let (runner, system) = make()
        system.tabsUnreadable = true
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: nil)
                == .failed(message: "The browser did not list its open tabs, so nothing was opened."))
        #expect(system.openedURLs.isEmpty)
    }

    @Test func aBrowserThatRefusedControlOpensNoDuplicateTab() async {
        let (runner, system) = make()
        system.refused = [chrome.bundleId]
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: nil)
                == .failed(message: "\(Branding.appName) is not allowed to control Google Chrome, so nothing was opened. Allow it in System Settings \u{2192} Privacy & Security \u{2192} Automation."))
        #expect(system.openedURLs.isEmpty)
    }

    @Test func aRefusalFromABrowserThatWouldNotOpenThePlaceIsIgnored() async {
        let (runner, system) = make()
        system.refused = ["com.apple.Safari"]
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: nil)
                == .done(summary: "Gmail", command: "No open tab matches, so it opens https://mail.google.com/."))
        #expect(system.openedURLs.map(\.0) == ["https://mail.google.com/"])
    }

    @Test func aRefusalIsCheckedAgainstTheBrowserThatOpensThatAddress() async {
        let (runner, system) = make()
        let plain = VoiceCommandPlace(name: "Wiki", target: .url("http://wiki.example/"))
        system.defaultBrowsers = ["https": "com.google.Chrome", "http": "com.apple.Safari"]
        system.refused = [chrome.bundleId]
        #expect(await runner.run(transcript: "switch to wiki", places: [plain], origin: nil)
                == .done(summary: "Wiki", command: "No open tab matches, so it opens http://wiki.example/."))
        #expect(system.defaultBrowserQueries == ["http://wiki.example/"])
    }

    @Test(arguments: [nil, "com.google.Chrome"])
    func aBrowserWhoseTabsCouldNotBeListedOpensNoDuplicate(browser: String?) async {
        let (runner, system) = make()
        let place = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"), browser: browser)
        system.unavailable = [chrome.bundleId]
        #expect(await runner.run(transcript: "switch to gmail", places: [place], origin: nil)
                == .failed(message: "Google Chrome did not list its open tabs, so nothing was opened."))
        #expect(system.openedURLs.isEmpty)
    }

    @Test func aScriptRetryStopsOnceTheCommandHasGivenUp() {
        var current = true
        var tried: [String] = []
        let answer: Int? = BrowserScripting.firstAnswer(["first", "retry"], isCurrent: { current }) { source in
            tried.append(source)
            current = false
            return nil
        }
        #expect(answer == nil)
        #expect(tried == ["first"])
    }

    @Test func onlyAppsWhoseScriptingDictionaryHasTabsAreAskedForTabs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-sdef-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func makeApp(_ name: String, sdef: String?) throws -> URL {
            let app = root.appendingPathComponent("\(name).app")
            let resources = app.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            var plist: [String: String] = ["CFBundleIdentifier": "test.\(name)", "CFBundlePackageType": "APPL"]
            if let sdef {
                plist["OSAScriptingDefinition"] = "\(name).sdef"
                try sdef.write(to: resources.appendingPathComponent("\(name).sdef"), atomically: true, encoding: .utf8)
            }
            try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }
        let browser = try makeApp("Browser", sdef: #"<dictionary><suite name="S"><class name="tab" code="Ctab"/></suite></dictionary>"#)
        let reordered = try makeApp("Reordered", sdef: #"<dictionary><suite name="S"><class code="Ctab" name="tab"/></suite></dictionary>"#)
        let wrapped = try makeApp("Wrapped", sdef: "<dictionary>\n<suite name=\"S\">\n<class\n    name = \"tab\"\n    code=\"Ctab\"/>\n</suite>\n</dictionary>")
        let tabsOnly = try makeApp("TabsOnly", sdef: #"<dictionary><suite name="tab"><class name="tabs" code="Ctbs"/></suite></dictionary>"#)
        let automation = try makeApp("Automation", sdef: #"<dictionary><suite name="S"><command name="execute"/></suite></dictionary>"#)
        let unscriptable = try makeApp("Plain", sdef: nil)
        #expect(LiveVoiceCommandSystem.hasScriptableTabs(browser))
        #expect(LiveVoiceCommandSystem.hasScriptableTabs(reordered))
        #expect(LiveVoiceCommandSystem.hasScriptableTabs(wrapped))
        #expect(!LiveVoiceCommandSystem.hasScriptableTabs(tabsOnly))
        #expect(!LiveVoiceCommandSystem.hasScriptableTabs(automation))
        #expect(!LiveVoiceCommandSystem.hasScriptableTabs(unscriptable))
    }

    @Test func aTabReadStopsAskingOnceItIsNoLongerWanted() {
        var current = true
        var asked: [String] = []
        let read = LiveVoiceCommandSystem.collectTabs(from: ["a", "b", "c"], isCurrent: { current }) { id in
            asked.append(id)
            current = false
            return .tabs([])
        }
        #expect(asked == ["a"])
        #expect(read == TabRead(tabs: []))
    }

    @Test func eachBrowserKeepsItsOwnReadOutcome() {
        let tab = VoiceCommandCatalog.Tab(browserBundleId: "a", window: 1, tab: 1, url: "https://a.example/", title: "A")
        let replies: [String: BrowserTabsReply] = ["a": .tabs([tab]), "b": .refused, "c": .unavailable]
        let read = LiveVoiceCommandSystem.collectTabs(from: ["a", "b", "c"], isCurrent: { true }) { replies[$0]! }
        #expect(read == TabRead(tabs: [tab], refused: ["b"], unavailable: ["c"]))
    }

    @Test func eitherNameOfAnAppReachesItRunningOrNotWithoutReadingWindows() async {
        let code = VoiceCommandCatalog.App(
            name: "Visual Studio Code", bundleId: "com.microsoft.VSCode", spokenNames: ["Visual Studio Code", "Code"])
        let done = VoiceCommandOutcome.done(
            summary: "Visual Studio Code", command: "Brings Visual Studio Code to the front, opening it if needed.")
        for running in [true, false] {
            let (runner, system) = make()
            system.installed = [running ? VoiceCommandCatalog.App(name: "Code Copy", bundleId: code.bundleId) : code]
            system.running = running ? [code] : []
            for name in ["code", "visual studio code"] {
                #expect(await runner.run(transcript: "switch to \(name)", places: [], origin: nil) == done)
            }
            #expect(system.windowReads == 0)
        }
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
                == .failed(message: "Not a command. Say \u{201C}switch to\u{201D} or \u{201C}open\u{201D} an app or place, \u{201C}run\u{201D} a script or shortcut, or \u{201C}go back\u{201D}.",
                           kind: .unrecognizedCommand))
        #expect(await runner.run(transcript: "switch to banana", places: [], origin: nil)
                == .failed(message: "No matching app, place, or window found for \u{201C}banana\u{201D}."))
    }

    @Test func onlyAGrammarMissIsMarkedUnrecognizedOnEveryEntryPath() async {
        let (runner, _) = make()
        guard case .failed(_, _, _, let kind) = await runner.run(.notACommand, origin: nil) else {
            Issue.record("expected a failure"); return
        }
        #expect(kind == .unrecognizedCommand)
        guard case .failed(_, _, _, let other) = await runner.run(transcript: "switch to banana", places: [], origin: nil) else {
            Issue.record("expected a failure"); return
        }
        #expect(other == .other)
    }

    @Test func anAppThatWillNotOpenFails() async {
        let (runner, system) = make()
        system.openSucceeds = false
        #expect(await runner.run(transcript: "switch to chrome", places: [], origin: nil)
                == .failed(message: "Could not switch to Google Chrome.",
                           command: "Brings Google Chrome to the front, opening it if needed."))
    }

    private let deploy = VoiceCommandScript(name: "Deploy", run: ["~/bin/deploy", "--env", "{text}"])

    @Test func aScriptRunsWithTheSpokenTextAsOneArgument() async {
        let (runner, system) = make()
        #expect(await runner.run(transcript: "Run deploy staging two.", places: [], scripts: [deploy], origin: nil)
            == .done(summary: "Deploy", command: "~/bin/deploy --env 'staging two'"))
        #expect(system.scriptRuns.map(\.program) == ["~/bin/deploy"])
        #expect(system.scriptRuns.map(\.arguments) == [["--env", "staging two"]])
        #expect(system.installedScans == 0)
        #expect(system.opened.isEmpty)
    }

    private func failureMessage(_ outcome: VoiceCommandOutcome) -> String? {
        if case .failed(let message, _, _, _) = outcome { return message }
        return nil
    }

    @Test func anInterpreterGivenTheTextIsRefusedWhenInvokedWhileOtherActionsStillRun() async {
        let (runner, system) = make()
        let shell = VoiceCommandScript(name: "Shell", run: ["/usr/bin/nice", "/bin/sh", "-c", "{text}"])
        let outcome = await runner.run(transcript: "run shell ls", places: [], scripts: [shell, deploy], origin: nil)
        #expect(failureMessage(outcome) == "Shell was not run. With {text}, “sh” could run spoken words as code. "
            + "Put the logic in an executable script file and choose that file instead.")
        #expect(system.scriptRuns.isEmpty)
        #expect(await runner.run(transcript: "run deploy prod", places: [], scripts: [shell, deploy], origin: nil)
            == .done(summary: "Deploy", command: "~/bin/deploy --env prod"))
    }

    @Test func aSymlinkToAnInterpreterIsRefusedAtLaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("helper")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/zsh"))
        let (runner, system) = make()
        let helper = VoiceCommandScript(name: "Helper", run: [link.path, "-c", "{text}"])
        let outcome = await runner.run(transcript: "run helper ls", places: [], scripts: [helper], origin: nil)
        #expect(failureMessage(outcome)?.hasPrefix("Helper was not run. With {text}, “zsh”") == true)
        #expect(system.scriptRuns.isEmpty)
    }

    @Test func aScriptThatIsStillRunningIsReportedAsStarted() async {
        let (runner, system) = make()
        system.scriptResult = .stillRunning
        #expect(await runner.run(transcript: "run deploy prod", places: [], scripts: [deploy], origin: nil)
            == .started(summary: "Deploy", command: "~/bin/deploy --env prod"))
    }

    @Test func aStartedScriptReportsHowItLaterFinished() async {
        let (runner, system) = make()
        system.scriptResult = .stillRunning
        var late: [VoiceCommandOutcome] = []
        _ = await runner.run(
            transcript: "run deploy prod", places: [], scripts: [deploy], origin: nil, onLateResult: { late.append($0) })
        system.finishLate?(.finished(status: 3, lastError: "timed out"))
        #expect(late == [.failed(message: "Deploy failed (exit 3): timed out", command: "~/bin/deploy --env prod")])
    }

    private let journal = VoiceCommandScript(
        name: "Journal", shortcut: VoiceCommandShortcut(name: "Journal Entry", identifier: "6E98", input: "{text}"))

    @Test func aShortcutRunsByIdentifierWithTheSpokenTextAsInput() async {
        let (runner, system) = make()
        #expect(await runner.run(transcript: "run journal buy milk", places: [], scripts: [journal], origin: nil)
            == .done(summary: "Journal",
                     command: "Runs the shortcut \u{201C}Journal Entry\u{201D} with \u{201C}buy milk\u{201D} as its input."))
        #expect(system.shortcutRuns.map(\.target) == ["6E98"])
        #expect(system.shortcutRuns.map(\.input) == ["buy milk"])
        #expect(system.scriptRuns.isEmpty)
    }

    @Test func aFailingShortcutReportsItsErrorWithoutAnExitStatus() async {
        let (runner, system) = make()
        system.scriptResult = .finished(status: 1, lastError: "Error: The shortcut could not be found.")
        #expect(await runner.run(transcript: "run journal buy milk", places: [], scripts: [journal], origin: nil)
            == .failed(message: "Journal failed: Error: The shortcut could not be found.",
                       command: "Runs the shortcut \u{201C}Journal Entry\u{201D} with \u{201C}buy milk\u{201D} as its input."))
    }

    @Test func aFailingScriptReportsItsExitStatusAndLastErrorLine() async {
        let (runner, system) = make()
        system.scriptResult = .finished(status: 2, lastError: "no such environment")
        #expect(await runner.run(transcript: "run deploy prod", places: [], scripts: [deploy], origin: nil)
            == .failed(message: "Deploy failed (exit 2): no such environment", command: "~/bin/deploy --env prod"))
        system.scriptResult = .finished(status: 1, lastError: nil)
        #expect(await runner.run(transcript: "run deploy prod", places: [], scripts: [deploy], origin: nil)
            == .failed(message: "Deploy failed (exit 1).", command: "~/bin/deploy --env prod"))
    }

    @Test func aMissingProgramIsNamed() async {
        let (runner, system) = make()
        system.scriptResult = .notRunnable
        #expect(await runner.run(transcript: "run deploy prod", places: [], scripts: [deploy], origin: nil)
            == .failed(
                message: "~/bin/deploy is not a program that can be run. Check the path, and that the file is executable.",
                command: "~/bin/deploy --env prod"))
    }

    @Test func aScriptWithoutItsTextDoesNotRun() async {
        let (runner, system) = make()
        #expect(await runner.run(transcript: "run deploy", places: [], scripts: [deploy], origin: nil)
            == .failed(message: "Say what to pass to Deploy after its name."))
        #expect(system.scriptRuns.isEmpty)
    }

    @Test func anAbandonedCommandNeverRunsTheScript() async {
        let (runner, system) = make()
        #expect(await runner.run(transcript: "run deploy prod", places: [], scripts: [deploy], origin: nil, stillWanted: { false })
            == .abandoned)
        #expect(system.scriptRuns.isEmpty)
    }

    @Test func aScriptDoesNotMoveTheBackTarget() async {
        let (runner, _) = make()
        _ = await runner.run(transcript: "switch to ghostty", places: [], origin: .init(bundleId: textEdit.bundleId))
        _ = await runner.run(transcript: "run deploy prod", places: [], scripts: [deploy], origin: .init(bundleId: ghostty.bundleId))
        #expect(runner.backTarget == .init(bundleId: textEdit.bundleId))
    }

    @Test func anUnknownRunTargetNeverSearchesOrOpensApps() async {
        let (runner, system) = make()
        #expect(await runner.run(transcript: "run ghostty", places: [], scripts: [deploy], origin: nil)
            == .failed(message: "No script or shortcut is called \u{201C}ghostty\u{201D}."))
        #expect(system.installedScans == 0)
        #expect(system.opened.isEmpty)
        #expect(system.scriptRuns.isEmpty)
    }
}
