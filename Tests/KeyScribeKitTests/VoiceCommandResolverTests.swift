import Testing
@testable import KeyScribeKit

struct VoiceCommandResolverTests {
    private typealias App = VoiceCommandCatalog.App
    private typealias Tab = VoiceCommandCatalog.Tab

    private let chrome = App(name: "Google Chrome", bundleId: "com.google.Chrome")
    private let ghostty = App(name: "Ghostty", bundleId: "com.mitchellh.ghostty")
    private let code = App(name: "Visual Studio Code", bundleId: "com.microsoft.VSCode")
    private let textEdit = App(name: "TextEdit", bundleId: "com.apple.TextEdit")
    private let safari = App(name: "Safari", bundleId: "com.apple.Safari")
    private let androidStudio = App(name: "Android Studio", bundleId: "com.google.android.studio")

    private func resolve(
        _ transcript: String, places: [VoiceCommandPlace] = [], running: [App] = [], installed: [App] = [],
        tabs: [Tab]? = nil, windows: VoiceCommandCatalog.WindowScan? = .complete([])
    ) -> VoiceCommandResolution {
        let catalog = VoiceCommandCatalog(
            places: places, runningApps: running, installedApps: installed, tabs: tabs, windows: windows)
        return VoiceCommandResolver.resolve(transcript, catalog: catalog)
    }

    @Test func notACommandIsReported() {
        #expect(resolve("hello there", running: [chrome]) == .notACommand)
    }

    @Test func goBackResolvesWithoutACatalog() {
        #expect(resolve("go back") == .action(.goBack))
    }

    @Test func runningAppByExactName() {
        #expect(resolve("switch to ghostty", running: [ghostty, chrome]) == .action(.app(ghostty)))
    }

    @Test func aSoundAlikePrefixResolvesTheSameApp() {
        #expect(resolve("Witch too Ghostty.", running: [ghostty, chrome]) == .action(.app(ghostty)))
    }

    @Test func runningAppByTrailingWords() {
        #expect(resolve("switch to chrome", running: [ghostty, chrome]) == .action(.app(chrome)))
        #expect(resolve("open code", running: [code]) == .action(.app(code)))
    }

    @Test func compactSpacingMatches() {
        #expect(resolve("switch to text edit", running: [textEdit]) == .action(.app(textEdit)))
    }

    @Test func installedAppIsFoundWhenNotRunning() {
        #expect(resolve("open safari", running: [chrome], installed: [safari, chrome]) == .action(.app(safari)))
    }

    @Test func runningBeatsInstalledForTheSameWords() {
        let otherChrome = App(name: "Chrome", bundleId: "com.example.chrome-shim")
        #expect(resolve("switch to chrome", running: [chrome], installed: [otherChrome]) == .action(.app(chrome)))
    }

    @Test func exactBeatsPartial() {
        let studio = App(name: "Studio", bundleId: "com.example.studio")
        #expect(resolve("switch to studio", running: [androidStudio, studio]) == .action(.app(studio)))
    }

    @Test func partialMatchesThatDisagreeAreAmbiguous() {
        let vsStudio = App(name: "Visual Studio", bundleId: "com.microsoft.visual-studio")
        #expect(ambiguousNames(resolve("switch to studio", running: [androidStudio, vsStudio]))
                == ["Android Studio", "Visual Studio"])
    }

    @Test func ambiguityListsAtMostFive() {
        let apps = (1...7).map { App(name: "Note \($0)", bundleId: "com.example.note\($0)") }
        guard case .ambiguous(let choice) = resolve("switch to note", running: apps) else {
            Issue.record("expected ambiguity"); return
        }
        #expect(choice.candidates.count == 5)
        #expect(choice.total == 7)
    }

    @Test func nearMissSnapsToARunningApp() {
        #expect(resolve("switch to ghosty", running: [ghostty, chrome]) == .action(.app(ghostty)))
    }

    @Test func equallyCloseNearMissesAreAmbiguousInAnyOrder() {
        let ghostey = App(name: "Ghostey", bundleId: "com.example.ghostey")
        #expect(ambiguousNames(resolve("open ghosty", running: [ghostty, ghostey])) == ["Ghostey", "Ghostty"])
        #expect(ambiguousNames(resolve("open ghosty", running: [ghostey, ghostty])) == ["Ghostey", "Ghostty"])
    }

    @Test func theCloserNearMissWins() {
        let ghosti = App(name: "Ghosti", bundleId: "com.example.ghosti")
        #expect(resolve("switch to ghostie", running: [ghostty, ghosti]) == .action(.app(ghosti)))
        #expect(resolve("switch to ghostie", running: [ghosti, ghostty]) == .action(.app(ghosti)))
    }

    @Test func aNearMissOnAPlaceStillBeatsTheSameNearMissOnAnApp() {
        let place = VoiceCommandPlace(name: "Chrome", target: .app(bundleId: chrome.bundleId))
        #expect(resolve("switch to crome", places: [place], running: [chrome])
                == .action(.place(place, .app(bundleId: chrome.bundleId))))
    }

    @Test func farMissIsNoMatch() {
        #expect(resolve("switch to banana", running: [ghostty, chrome]) == .noMatch("banana"))
    }

    @Test func fuzzyNeverReachesInstalledOnlyApps() {
        let ghosttyInstalled = App(name: "Ghostty", bundleId: "com.mitchellh.ghostty")
        #expect(resolve("switch to ghosty", running: [], installed: [ghosttyInstalled]) == .noMatch("ghosty"))
    }

    @Test func aPlaceNicknameBeatsAnAppName() {
        let place = VoiceCommandPlace(name: "Editor", say: ["code"], target: .app(bundleId: code.bundleId))
        let codeShim = App(name: "Code", bundleId: "com.example.code")
        #expect(resolve("open code", places: [place], running: [codeShim, code])
                == .action(.place(place, .app(bundleId: code.bundleId))))
    }

    @Test func aPlaceIsMatchedByItsName() {
        let place = VoiceCommandPlace(name: "Work Mail", target: .url("https://mail.google.com/mail/u/1/"))
        #expect(resolve("switch to work mail", places: [place], tabs: [])
                == .action(.place(place, .openURL("https://mail.google.com/mail/u/1/", browser: nil))))
    }

    @Test func aURLPlaceNeedsTabsBeforeItCanResolve() {
        let place = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"))
        #expect(resolve("switch to gmail", places: [place], tabs: nil) == .needsTabs(browser: nil))
    }

    @Test func aBrowserScopedPlaceAsksForThatBrowsersTabsOnly() {
        let place = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"), browser: safari.bundleId)
        #expect(resolve("switch to gmail", places: [place], tabs: nil) == .needsTabs(browser: safari.bundleId))
    }

    @Test func aURLPlacePrefersAnOpenTab() {
        let place = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"))
        let tabs = [
            Tab(browserBundleId: chrome.bundleId, window: 1, tab: 1, url: "https://example.com/", title: "Example"),
            Tab(browserBundleId: chrome.bundleId, window: 2, tab: 3, url: "https://mail.google.com/mail/u/0/#inbox", title: "Inbox"),
        ]
        #expect(resolve("switch to gmail", places: [place], tabs: tabs)
                == .action(.place(place, .tab(tabs[1]))))
    }

    @Test func tabMatchingIgnoresSchemeCaseAndTrailingSlash() {
        let place = VoiceCommandPlace(name: "Docs", target: .url("http://Docs.Example.com"))
        let tab = Tab(browserBundleId: safari.bundleId, window: 1, tab: 2, url: "https://docs.example.com/guide", title: "Guide")
        #expect(resolve("go to docs", places: [place], tabs: [tab]) == .action(.place(place, .tab(tab))))
    }

    @Test func tabMatchingKeepsPathQueryAndFragmentCase() {
        let place = VoiceCommandPlace(name: "Project", target: .url("https://example.com/Project?View=All#Top"))
        let other = Tab(browserBundleId: safari.bundleId, window: 1, tab: 1, url: "https://example.com/project?view=all#top", title: "Other")
        let same = Tab(browserBundleId: safari.bundleId, window: 1, tab: 2, url: "https://EXAMPLE.com/Project?View=All#Top", title: "Project")
        #expect(resolve("go to project", places: [place], tabs: [other])
                == .action(.place(place, .openURL("https://example.com/Project?View=All#Top", browser: nil))))
        #expect(resolve("go to project", places: [place], tabs: [other, same]) == .action(.place(place, .tab(same))))
    }

    @Test func tabMatchingIgnoresWwwOnlyInTheHost() {
        #expect(VoiceCommandResolver.urlMatches("https://www.example.com/a", place: "example.com/a"))
        #expect(VoiceCommandResolver.urlMatches("https://example.com/a", place: "https://www.example.com/a"))
        #expect(VoiceCommandResolver.urlMatches("https://example.com/", place: "https://example.com"))
        #expect(VoiceCommandResolver.urlMatches("https://example.com?q=1", place: "https://example.com"))
    }

    @Test func tabMatchingRespectsHostBoundaries() {
        let place = VoiceCommandPlace(name: "Mail", target: .url("https://mail.example.com"))
        let tab = Tab(browserBundleId: safari.bundleId, window: 1, tab: 1, url: "https://mail.example.community/", title: "Other")
        #expect(resolve("go to mail", places: [place], tabs: [tab])
                == .action(.place(place, .openURL("https://mail.example.com", browser: nil))))
    }

    @Test func tabMatchingHonorsTheBrowserFilter() {
        let place = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"), browser: safari.bundleId)
        let chromeTab = Tab(browserBundleId: chrome.bundleId, window: 1, tab: 1, url: "https://mail.google.com/", title: "Inbox")
        let safariTab = Tab(browserBundleId: safari.bundleId, window: 1, tab: 4, url: "https://mail.google.com/x", title: "Inbox")
        #expect(resolve("switch to gmail", places: [place], tabs: [chromeTab])
                == .action(.place(place, .openURL("https://mail.google.com/", browser: safari.bundleId))))
        #expect(resolve("switch to gmail", places: [place], tabs: [chromeTab, safariTab])
                == .action(.place(place, .tab(safariTab))))
    }

    @Test func twoPlacesSharingANicknameAreAmbiguous() {
        let personal = VoiceCommandPlace(name: "Personal Mail", say: ["mail"], target: .url("https://mail.google.com/mail/u/0/"))
        let work = VoiceCommandPlace(name: "Work Mail", say: ["mail"], target: .url("https://mail.google.com/mail/u/1/"))
        #expect(ambiguousNames(resolve("switch to mail", places: [personal, work], tabs: []))
                == ["Personal Mail", "Work Mail"])
    }

    @Test func theSameAppRunningTwiceIsNotAmbiguous() {
        #expect(resolve("switch to chrome", running: [chrome, chrome]) == .action(.app(chrome)))
    }

    @Test func summaryNamesTheDestination() {
        let place = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"))
        let tab = Tab(browserBundleId: chrome.bundleId, window: 1, tab: 1, url: "https://mail.google.com/", title: "Inbox")
        #expect(VoiceCommandAction.app(chrome).summary(appName: { _ in nil }) == "Google Chrome")
        #expect(VoiceCommandAction.place(place, .tab(tab)).summary(appName: { $0 == chrome.bundleId ? "Google Chrome" : nil })
                == "Gmail · Google Chrome")
        #expect(VoiceCommandAction.goBack.summary(appName: { _ in nil }) == "Back")
    }
}


func ambiguousNames(_ resolution: VoiceCommandResolution) -> [String]? {
    guard case .ambiguous(let choice) = resolution else { return nil }
    return choice.candidates.map(\.name)
}
