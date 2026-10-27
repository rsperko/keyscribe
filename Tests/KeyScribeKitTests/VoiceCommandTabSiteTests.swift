import Testing
@testable import KeyScribeKit

struct VoiceCommandTabSiteTests {
    private typealias Tab = VoiceCommandCatalog.Tab

    private let chromeId = "com.google.Chrome"
    private var chrome: VoiceCommandPlace { VoiceCommandPlace(name: "Chrome", target: .tabSearch, browser: chromeId) }

    private func tab(_ title: String, at url: String, tab: Int = 1) -> Tab {
        Tab(browserBundleId: chromeId, window: 1, tab: tab, url: url, title: title)
    }

    private func resolve(_ transcript: String, places: [VoiceCommandPlace] = [], tabs: [Tab]) -> VoiceCommandResolution {
        VoiceCommandResolver.resolve(transcript, catalog: VoiceCommandCatalog(places: places, tabs: tabs, windows: .complete([])))
    }

    @Test(arguments: [
        ("https://github.com/org/repo", "github"),
        ("https://www.github.com/", "github"),
        ("http://grafana.example.com/d/abc", "grafana example"),
        ("https://www.bbc.co.uk/news", "bbc"),
        ("https://my-site.example.org", "my site example"),
    ])
    func aTabIsNamedAfterItsSite(url: String, site: String) {
        #expect(tab("Anything", at: url).siteName == site)
    }

    @Test(arguments: ["http://localhost:3000/", "http://192.168.1.10/", "chrome://settings", "file:///tmp/a.html", "about:blank"])
    func aTabWithoutAPublicSiteHasNoSiteName(url: String) {
        #expect(tab("Anything", at: url).siteName == nil)
    }

    @Test func aGenericTitleIsFoundByItsSite() {
        let grafana = tab("Dashboard", at: "https://grafana.example.com/d/abc", tab: 2)
        let other = tab("Dashboard", at: "https://status.example.net/", tab: 3)
        #expect(resolve("chrome grafana", places: [chrome], tabs: [other, grafana]) == .action(.tab(grafana)))
        #expect(resolve("switch to grafana", tabs: [other, grafana]) == .action(.tab(grafana)))
    }

    @Test func aMisheardSiteStillMatches() {
        let grafana = tab("Dashboard", at: "https://grafana.example.com/d/abc")
        #expect(resolve("chrome graffana", places: [chrome], tabs: [tab("Inbox", at: "https://mail.example.org/"), grafana])
            == .action(.tab(grafana)))
    }

    @Test func aSiteSpellingDoesNotBlockCorrectingTheTitle() {
        let notes = tab("Ghostty Notes", at: "https://ghosty.example.com/")
        #expect(resolve("chrome ghosty notes", places: [chrome], tabs: [notes]) == .action(.tab(notes)))
    }

    @Test func aTitleMatchWinsOverASiteMatch() {
        let named = tab("GitHub Status", at: "https://www.githubstatus.com/", tab: 1)
        let onSite = tab("Pull requests", at: "https://github.com/pulls", tab: 2)
        #expect(resolve("chrome github status", places: [chrome], tabs: [onSite, named]) == .action(.tab(named)))
        #expect(resolve("chrome github", places: [chrome], tabs: [onSite]) == .action(.tab(onSite)))
    }

    @Test func severalTabsOnOneSiteGoToTheLeftmost() {
        let pulls = tab("Pull requests", at: "https://github.com/pulls", tab: 1)
        let issues = tab("Issues", at: "https://github.com/issues", tab: 2)
        #expect(resolve("chrome github", places: [chrome], tabs: [issues, pulls]) == .action(.tab(pulls)))
    }
}
