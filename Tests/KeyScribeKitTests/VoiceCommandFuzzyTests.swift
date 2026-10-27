import Testing
@testable import KeyScribeKit

struct VoiceCommandFuzzyTests {
    private typealias App = VoiceCommandCatalog.App
    private typealias Tab = VoiceCommandCatalog.Tab
    private typealias Window = VoiceCommandCatalog.Window

    private let brave = App(name: "Brave Browser", bundleId: "com.brave.Browser")
    private let code = App(name: "Visual Studio Code", bundleId: "com.microsoft.VSCode")
    private let ghostty = App(name: "Ghostty", bundleId: "com.mitchellh.ghostty")

    private func tab(_ title: String, window: Int = 1, tab: Int = 1, url: String = "https://example.com/") -> Tab {
        Tab(browserBundleId: brave.bundleId, window: window, tab: tab, url: url, title: title)
    }

    private func window(_ title: String, id: String = "cg:1") -> Window {
        Window(bundleId: code.bundleId, appName: code.name, pid: 10, id: id, title: title)
    }

    private func resolve(
        _ transcript: String, places: [VoiceCommandPlace] = [], running: [App] = [], installed: [App] = [],
        tabs: [Tab]? = [], windows: VoiceCommandCatalog.WindowScan? = .complete([])
    ) -> VoiceCommandResolution {
        VoiceCommandResolver.resolve(transcript, catalog: VoiceCommandCatalog(
            places: places, runningApps: running, installedApps: installed, tabs: tabs, windows: windows))
    }

    @Test func aBackgroundTabIsReachedByATitleSegment() {
        let ha = tab("Settings \u{2013} Home Assistant", tab: 4)
        #expect(resolve("switch to home assistant", tabs: [tab("Inbox"), ha]) == .action(.tab(ha)))
    }

    @Test func tabsAreReadOnlyAfterWindowsMiss() {
        #expect(resolve("switch to home assistant", tabs: nil, windows: nil) == .needsWindows)
        #expect(resolve("switch to home assistant", tabs: nil) == .needsTabs(browser: nil))
        let doc = window("Home Assistant")
        #expect(resolve("switch to home assistant", tabs: nil, windows: .complete([doc])) == .action(.window(doc)))
    }

    @Test func aWindowShowingTheSameTitleBeatsItsTab() {
        let doc = window("Home Assistant")
        let ha = tab("Home Assistant")
        #expect(resolve("switch to home assistant", tabs: [ha], windows: .complete([doc])) == .action(.window(doc)))
    }

    @Test func aMisheardTabTitleSnapsToTheTab() {
        let master = tab("Season 2, Episode 4 | Taskmaster - YouTube", tab: 2)
        #expect(resolve("switch to task master", tabs: [tab("Inbox"), master]) == .action(.tab(master)))
        #expect(resolve("switch to taskmastr", tabs: [tab("Inbox"), master]) == .action(.tab(master)))
    }

    @Test func titleWordsMatchInAnyOrder() {
        let run = tab("Afternoon Run | Run | Strava", tab: 3)
        #expect(resolve("switch to strava run", tabs: [tab("Inbox"), run]) == .action(.tab(run)))
        let notes = window("Quarterly Budget Review")
        #expect(resolve("switch to quarterly review", windows: .complete([notes])) == .action(.window(notes)))
    }

    @Test func aNearMissReachesAWindow() {
        let doc = window("Keyscribe")
        #expect(resolve("switch to keyscrib", windows: .complete([doc])) == .action(.window(doc)))
    }

    @Test func aNearMissReachesAnInstalledApp() {
        #expect(resolve("open ghosty", installed: [ghostty]) == .action(.app(ghostty)))
    }

    @Test func aNearMissOnARunningAppStillBeatsTheSameMissOnATab() {
        #expect(resolve("switch to ghosty", running: [ghostty], tabs: [tab("Ghostty")]) == .action(.app(ghostty)))
    }

    @Test func farMissesStillMatchNothing() {
        #expect(resolve("switch to banana", running: [ghostty], installed: [code], tabs: [tab("Inbox")],
                        windows: .complete([window("Keyscribe")])) == .noMatch("banana"))
    }

    @Test func tabsTiedOnTitleInOneBrowserGoToTheLeftmost() {
        let first = tab("Login - oMLX Admin", tab: 1)
        let second = tab("Dashboard - oMLX Admin", tab: 2)
        #expect(resolve("switch to omlx admin", tabs: [second, first]) == .action(.tab(first)))
    }

    @Test func aTabCandidateHasAStableIdentityAndNamesItsSite() {
        let ha = tab("Home Assistant", window: 2, tab: 7, url: "https://www.home.example.com/config")
        #expect(VoiceCommandCandidate.tab(ha).identity == "tab:com.brave.Browser:2:7:https://www.home.example.com/config")
        #expect(VoiceCommandCandidate.tab(ha).name == "Home Assistant")
        #expect(VoiceCommandCandidate.tab(ha).detail(appName: { $0 == "com.brave.Browser" ? "Brave" : nil }, among: [])
                == "Brave \u{00B7} home.example.com")
    }

    @Test func aChosenTabResolvesToFocusingIt() {
        let ha = tab("Home Assistant")
        #expect(VoiceCommandResolver.resolve(.tab(ha), text: "", reach: .opening, catalog: VoiceCommandCatalog()) == .action(.tab(ha)))
    }
}
