import Testing
@testable import KeyScribeKit

struct WindowTitleTests {
    @Test func splitsAtEachSeparator() {
        #expect(WindowTitle.segments("a.md \u{2014} keyscribe") == ["a.md", "keyscribe"])
        #expect(WindowTitle.segments("Budget \u{2013} Numbers") == ["Budget", "Numbers"])
        #expect(WindowTitle.segments("Google Meet - Brave") == ["Google Meet", "Brave"])
        #expect(WindowTitle.segments("Inbox | Mail") == ["Inbox", "Mail"])
        #expect(WindowTitle.segments("Improv \u{00B7} zkmd") == ["Improv", "zkmd"])
        #expect(WindowTitle.segments("Plan \u{2022} Reference") == ["Plan", "Reference"])
        #expect(WindowTitle.segments("host: Scribe") == ["host", "Scribe"])
    }

    @Test func keepsATitleWithoutSeparatorsWhole() {
        #expect(WindowTitle.segments("Who's using Chrome?") == ["Who's using Chrome?"])
        #expect(WindowTitle.segments("well-known 10:30") == ["well-known 10:30"])
    }

    @Test func dropsEmptySegments() {
        #expect(WindowTitle.segments(" \u{2014} keyscribe \u{2014} ") == ["keyscribe"])
    }
}

struct VoiceCommandWindowResolverTests {
    private typealias App = VoiceCommandCatalog.App
    private typealias Window = VoiceCommandCatalog.Window

    private let code = App(name: "Visual Studio Code", bundleId: "com.microsoft.VSCode")
    private let chrome = App(name: "Google Chrome", bundleId: "com.google.Chrome")
    private let slack = App(name: "Slack", bundleId: "com.tinyspeck.slackmacgap")

    private func window(
        _ title: String, app: App? = nil, pid: Int32 = 10, id: String = "cg:1", document: String? = nil
    ) -> Window {
        let app = app ?? code
        return Window(bundleId: app.bundleId, appName: app.name, pid: pid, id: id, title: title, document: document)
    }

    private func resolve(
        _ transcript: String, places: [VoiceCommandPlace] = [], running: [App] = [], installed: [App] = [],
        windows: VoiceCommandCatalog.WindowScan?
    ) -> VoiceCommandResolution {
        VoiceCommandResolver.resolve(transcript, catalog: VoiceCommandCatalog(
            places: places, runningApps: running, installedApps: installed, tabs: [], windows: windows))
    }

    private func names(_ resolution: VoiceCommandResolution) -> [String] {
        guard case .ambiguous(let choice) = resolution else { return [] }
        return choice.candidates.map(\.name)
    }

    @Test func aTitleSegmentSelectsTheWindow() {
        let editor = window("plan.md \u{2014} keyscribe")
        #expect(resolve("switch to keyscribe", running: [code], windows: .complete([editor])) == .action(.window(editor)))
    }

    @Test func theWholeTitleSelectsTheWindow() {
        let meet = window("Google Meet - Brave", app: chrome)
        #expect(resolve("switch to google meet brave", windows: .complete([meet])) == .action(.window(meet)))
    }

    @Test func anExactSegmentBeatsAPartialMatch() {
        let exact = window("Budget \u{2014} Numbers", id: "cg:1")
        let partial = window("Budget Review Notes", id: "cg:2")
        #expect(resolve("switch to budget", windows: .complete([partial, exact])) == .action(.window(exact)))
    }

    @Test func partialNeedsContiguousWordsAndTheMinimumLength() {
        let notes = window("Quarterly Budget Review", id: "cg:1")
        #expect(resolve("switch to budget review", windows: .complete([notes])) == .action(.window(notes)))
        #expect(resolve("switch to quarterly review", windows: .complete([notes])) == .noMatch("quarterly review"))
        let short = window("Go Plan", id: "cg:2")
        #expect(resolve("switch to go", windows: .complete([short])) == .noMatch("go"))
    }

    @Test func placesAndRunningAppsOutrankWindows() {
        let named = window("Visual Studio Code", app: chrome)
        #expect(resolve("switch to visual studio code", running: [code], windows: .complete([named])) == .action(.app(code)))
        let place = VoiceCommandPlace(name: "Budget", target: .app(bundleId: code.bundleId))
        let budget = window("Budget", app: chrome)
        #expect(resolve("switch to budget", places: [place], windows: .complete([budget]))
                == .action(.place(place, .app(bundleId: code.bundleId))))
    }

    @Test func anExactInstalledAppNameBeatsAWindowWithoutReadingWindows() {
        #expect(resolve("open slack", installed: [slack], windows: nil) == .action(.app(slack)))
        let download = window("Download Slack", app: chrome)
        #expect(resolve("open slack", installed: [slack], windows: .complete([download])) == .action(.app(slack)))
        #expect(resolve("switch to download slack", installed: [slack], windows: .complete([download])) == .action(.window(download)))
    }

    @Test func aWindowOutranksAnInstalledAppPartialMatch() {
        let studio = App(name: "Android Studio", bundleId: "com.google.android.studio")
        let doc = window("Studio \u{2014} Notes")
        #expect(resolve("switch to studio", installed: [studio], windows: .complete([doc])) == .action(.window(doc)))
        #expect(resolve("switch to studio", installed: [studio], windows: .complete([])) == .action(.app(studio)))
    }

    @Test func windowsAreReadOnlyWhenTheEarlierTiersMiss() {
        #expect(resolve("switch to keyscribe", running: [code], windows: nil) == .needsWindows)
        #expect(resolve("switch to code", running: [code], windows: nil) == .action(.app(code)))
    }

    @Test func anUnfinishedScanNeverFallsThroughToAWeakerMatch() {
        let studio = App(name: "Android Studio", bundleId: "com.google.android.studio")
        #expect(resolve("switch to studio", installed: [studio], windows: .incomplete) == .windowsIncomplete)
        #expect(resolve("switch to studio", installed: [studio], windows: .needsAccessibility) == .windowsNeedAccessibility)
        #expect(resolve("switch to cod", running: [code], windows: .incomplete) == .windowsIncomplete)
    }

    @Test func aNearMissNeverProposesAWindow() {
        let doc = window("Keyscribe")
        #expect(resolve("switch to keyscrib", windows: .complete([doc])) == .noMatch("keyscrib"))
    }

    @Test func sameTitledWindowsTieWithDistinctIdentities() {
        let first = window("README.md", pid: 10, id: "cg:1")
        let second = window("README.md", pid: 10, id: "cg:2")
        let otherProcess = window("README.md", pid: 11, id: "cg:1")
        guard case .ambiguous(let choice) = resolve("switch to readme md", windows: .complete([first, second, otherProcess])) else {
            Issue.record("expected a choice"); return
        }
        #expect(Set(choice.candidates.map(\.identity)).count == 3)
        #expect(choice.candidates.map(\.identity) == [
            "window:com.microsoft.VSCode:10:cg:1", "window:com.microsoft.VSCode:10:cg:2", "window:com.microsoft.VSCode:11:cg:1",
        ])
    }

    @Test func windowsAreOrderedByAppThenInTheOrderTheyWereListed() {
        let back = window("Budget Draft", app: code, id: "cg:3")
        let front = window("Budget Final", app: code, id: "cg:2")
        let other = window("Budget Sheet", app: chrome, id: "cg:9")
        #expect(names(resolve("switch to budget", windows: .complete([front, back, other])))
                == ["Budget Sheet", "Budget Final", "Budget Draft"])
    }

    @Test func aRowNamesItsAppAndOnlyTiedRowsGetTheDocument() {
        let a = window("README.md", id: "cg:1", document: "file:///Users/me/src/alpha/README.md")
        let b = window("README.md", id: "cg:2", document: "file:///Users/me/src/beta/README.md")
        let c = window("Release Notes", app: chrome, id: "cg:3", document: "https://www.example.org/notes")
        let all: [VoiceCommandCandidate] = [.window(a), .window(b), .window(c)]
        #expect(all.map { $0.detail(appName: { _ in nil }, among: all) } == [
            "Visual Studio Code \u{00B7} alpha/README.md", "Visual Studio Code \u{00B7} beta/README.md", "Google Chrome",
        ])
        let web = window("Inbox", app: chrome, id: "cg:4", document: "https://www.example.org/a")
        let web2 = window("Inbox", app: chrome, id: "cg:5", document: "https://mail.example.net/b")
        let pair: [VoiceCommandCandidate] = [.window(web), .window(web2)]
        #expect(pair.map { $0.detail(appName: { _ in nil }, among: pair) }
                == ["Google Chrome \u{00B7} example.org", "Google Chrome \u{00B7} mail.example.net"])
    }

    @Test func rowsThatStillReadTheSameSayWhichIsFurtherForwardOnlyWithinOneProcess() {
        let a = window("Terminal", id: "cg:1")
        let b = window("Terminal", id: "cg:2")
        let distinct = window("Terminal", id: "cg:3", document: "file:///tmp/x")
        let otherProcess = window("Terminal", pid: 11, id: "cg:4")
        let budget = window("Budget", app: chrome, id: "cg:5")
        #expect(VoiceCommandChoice(family: .navigation, target: "terminal", matches: [.window(a), .window(b)]).note
                == "Same name; the lower number is further forward.")
        #expect(VoiceCommandChoice(family: .navigation, target: "x", matches: [.window(budget), .window(a), .window(b)]).note
                == "Same name; the lower number is further forward.")
        #expect(VoiceCommandChoice(family: .navigation, target: "terminal", matches: [.window(a), .window(otherProcess)]).note
                == "Same name; these windows can\u{2019}t be told apart.")
        #expect(VoiceCommandChoice(family: .navigation, target: "terminal", matches: [.window(a), .window(distinct)]).note == nil)
        #expect(VoiceCommandChoice(family: .navigation, target: "x", matches: [.app(code), .app(chrome)]).note == nil)
    }

    @Test func aChosenWindowResolvesToItselfEvenIfNamesChanged() {
        let chosen = window("Budget", id: "cg:7")
        let renamed = VoiceCommandCatalog(runningApps: [App(name: "Budget", bundleId: "com.example.budget")])
        #expect(VoiceCommandResolver.resolve(.window(chosen), text: "", catalog: renamed) == .action(.window(chosen)))
    }

    @Test func windowCopy() {
        let doc = window("plan.md \u{2014} keyscribe")
        let action = VoiceCommandAction.window(doc)
        #expect(action.summary(appName: { _ in nil }) == "plan.md \u{2014} keyscribe \u{00B7} Visual Studio Code")
        #expect(action.detail(appName: { _ in nil })
                == "Brings the window \u{201C}plan.md \u{2014} keyscribe\u{201D} in Visual Studio Code to the front.")
        #expect(action.command(appName: { _ in nil }) == action.detail(appName: { _ in nil }))
    }
}
