import Testing
@testable import KeyScribeKit

struct VoiceCommandQuickSwitchTests {
    private typealias Tab = VoiceCommandCatalog.Tab

    private let chromeId = "com.google.Chrome"
    private var quick: VoiceCommandPlace {
        VoiceCommandPlace(name: "Chrome", target: .tabSearch, browser: chromeId, quickSwitch: true)
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
        let anyBrowser = VoiceCommandPlace(name: "Tab", target: .tabSearch, quickSwitch: true)
        let safari = Tab(browserBundleId: "com.apple.Safari", window: 1, tab: 1, url: "https://github.com/", title: "Issues")
        let chrome = tab("Pull requests", window: 1, tab: 5)
        guard case .ambiguous(let choice) = resolve("tab github", place: anyBrowser, tabs: [safari, chrome]) else {
            Issue.record("expected a choice"); return
        }
        #expect(choice.candidates == [.tab(safari), .tab(chrome)])
    }

    @Test func tiesInOneBrowserSwitchEvenWhenAnyBrowserIsSearched() {
        let anyBrowser = VoiceCommandPlace(name: "Tab", target: .tabSearch, quickSwitch: true)
        let back = tab("Pull requests", window: 2, tab: 1)
        let front = tab("Issues", window: 1, tab: 4)
        #expect(resolve("tab github", place: anyBrowser, tabs: [back, front]) == .action(.tab(front)))
    }

    @Test func withoutQuickSwitchSeveralMatchesStillAsk() {
        let place = VoiceCommandPlace(name: "Chrome", target: .tabSearch, browser: chromeId)
        guard case .ambiguous = resolve("chrome github", place: place, tabs: [tab("A", window: 1, tab: 1), tab("B", window: 1, tab: 2)])
        else { Issue.record("expected a choice"); return }
    }

    @Test func quickSwitchRoundTripsAndIsOmittedWhenOff() throws {
        let off = VoiceCommandPlace(name: "Tabs", target: .tabSearch)
        let config = VoiceCommandConfig(places: [quick, off])
        let toml = try VoiceCommandStore.encode(config)
        #expect(try VoiceCommandStore.decode(from: toml) == config)
        #expect(toml.components(separatedBy: "quick_switch").count == 2)
    }

    @Test func quickSwitchAppliesOnlyToATabSearch() {
        let toml = """
        schema_version = 1

        [[command]]
        name = "Mail"
        app = "com.apple.mail"
        quick_switch = true
        """
        #expect(throws: ConfigError.self) { try VoiceCommandStore.decode(from: toml) }
    }
}
