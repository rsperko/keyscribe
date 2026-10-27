import Testing
@testable import KeyScribeKit

struct VoiceCommandTabTieTests {
    private typealias Tab = VoiceCommandCatalog.Tab

    private let chromeId = "com.google.Chrome"
    private var quick: VoiceCommandPlace {
        VoiceCommandPlace(name: "Chrome", target: .tabSearch, browser: chromeId)
    }

    private func tab(_ title: String, window: Int, tab: Int, url: String = "https://github.com/") -> Tab {
        Tab(browserBundleId: chromeId, window: window, tab: tab, url: url, title: title)
    }

    private func resolve(_ transcript: String, place: VoiceCommandPlace, tabs: [Tab]) -> VoiceCommandResolution {
        VoiceCommandResolver.resolve(transcript, catalog: VoiceCommandCatalog(places: [place], tabs: tabs, windows: .complete([])))
    }

    @Test func severalMatchesGoToTheFrontWindowsLeftmostTab() {
        let back = tab("Pull requests", window: 2, tab: 1)
        let right = tab("Issues", window: 1, tab: 5)
        let left = tab("Actions", window: 1, tab: 3)
        #expect(resolve("chrome github", place: quick, tabs: [back, right, left]) == .action(.tab(left)))
    }

    @Test func moreMatchesThanAChooserShowsStillSwitch() {
        let tabs = (1...(VoiceCommandChoice.displayLimit + 2)).map { tab("Page \($0)", window: 1, tab: 10 - $0) }
        #expect(resolve("chrome github", place: quick, tabs: tabs) == .action(.tab(tabs[tabs.count - 1])))
    }

    @Test func aBetterMatchStillWins() {
        let issues = tab("Issues", window: 1, tab: 1)
        let pulls = tab("Pull requests", window: 2, tab: 4)
        #expect(resolve("chrome pull requests", place: quick, tabs: [issues, pulls]) == .action(.tab(pulls)))
    }

    @Test func aMisheardNameStillSwitches() {
        let back = tab("Release notes", window: 2, tab: 1)
        let front = tab("Release notes", window: 1, tab: 2)
        #expect(resolve("chrome relese notes", place: quick, tabs: [back, front]) == .action(.tab(front)))
    }

    @Test func tiesInDifferentBrowsersStillAsk() {
        let anyBrowser = VoiceCommandPlace(name: "Tab", target: .tabSearch)
        let safari = Tab(browserBundleId: "com.apple.Safari", window: 1, tab: 1, url: "https://github.com/", title: "Issues")
        let chrome = tab("Pull requests", window: 1, tab: 5)
        guard case .ambiguous(let choice) = resolve("tab github", place: anyBrowser, tabs: [safari, chrome]) else {
            Issue.record("expected a choice"); return
        }
        #expect(choice.candidates == [.tab(safari), .tab(chrome)])
    }

    @Test func tiesInOneBrowserSwitchEvenWhenAnyBrowserIsSearched() {
        let anyBrowser = VoiceCommandPlace(name: "Tab", target: .tabSearch)
        let back = tab("Pull requests", window: 2, tab: 1)
        let front = tab("Issues", window: 1, tab: 4)
        #expect(resolve("tab github", place: anyBrowser, tabs: [back, front]) == .action(.tab(front)))
    }

    @Test func anAppNameAndWordsAlsoGoToTheFrontmostTie() {
        var catalog = VoiceCommandCatalog(
            runningApps: [VoiceCommandCatalog.App(name: "Chrome", bundleId: chromeId)],
            tabs: [tab("Issues", window: 2, tab: 1), tab("Pulls", window: 1, tab: 4)], windows: .complete([]))
        catalog.findsInApps = true
        catalog.tabBrowsers = [chromeId]
        #expect(VoiceCommandResolver.resolve("open chrome github", catalog: catalog)
                == .action(.tab(tab("Pulls", window: 1, tab: 4))))
    }

    @Test func anOldQuickSwitchSettingIsReadAndDroppedOnSave() throws {
        let toml = """
        schema_version = 1

        [[command]]
        name = "Chrome"
        find_tab = true
        browser = "\(chromeId)"
        quick_switch = true
        """
        let config = try VoiceCommandStore.decode(from: toml)
        #expect(config.places == [VoiceCommandPlace(name: "Chrome", target: .tabSearch, browser: chromeId)])
        #expect(VoiceCommandStore.unknownKeys(in: toml).isEmpty)
        #expect(!(try VoiceCommandStore.encode(config)).contains("quick_switch"))
    }
}
