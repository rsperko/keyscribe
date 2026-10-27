import Testing
@testable import KeyScribeKit

struct VoiceCommandReachTests {
    private typealias App = VoiceCommandCatalog.App
    private typealias Tab = VoiceCommandCatalog.Tab

    private let slack = App(name: "Slack", bundleId: "com.tinyspeck.slackmacgap")
    private let ghostty = App(name: "Ghostty", bundleId: "com.mitchellh.ghostty")
    private let chrome = App(name: "Google Chrome", bundleId: "com.google.Chrome")
    private let notes = App(name: "Notes", bundleId: "com.apple.Notes")

    private func catalog(
        places: [VoiceCommandPlace] = [], scripts: [VoiceCommandScript] = [], running: [App] = [], installed: [App] = [],
        tabs: [Tab]? = [], windows: [VoiceCommandCatalog.Window] = [], findsInApps: Bool = false
    ) -> VoiceCommandCatalog {
        var catalog = VoiceCommandCatalog(
            places: places, scripts: scripts, runningApps: running, installedApps: installed, tabs: tabs, windows: .complete(windows))
        catalog.findsInApps = findsInApps
        catalog.tabBrowsers = [chrome.bundleId]
        return catalog
    }

    private func resolve(_ transcript: String, _ catalog: VoiceCommandCatalog) -> VoiceCommandResolution {
        VoiceCommandResolver.resolve(transcript, catalog: catalog)
    }

    private func window(_ title: String, app: App) -> VoiceCommandCatalog.Window {
        VoiceCommandCatalog.Window(bundleId: app.bundleId, appName: app.name, pid: 7, id: "cg:\(title.count)", title: title)
    }

    @Test(arguments: ["switch to slack", "go to slack", "focus slack", "focus on slack", "which two slack"])
    func switchingToAClosedAppExplainsInsteadOfOpening(_ phrase: String) {
        #expect(resolve(phrase, catalog(installed: [slack]))
                == .closed(.app(bundleId: slack.bundleId, say: "open Slack", find: nil)))
    }

    @Test(arguments: ["open slack", "launch slack"])
    func openingAClosedAppOpensIt(_ phrase: String) {
        #expect(resolve(phrase, catalog(installed: [slack])) == .action(.app(slack)))
    }

    @Test func bothVerbsReachARunningApp() {
        let running = catalog(running: [slack], installed: [slack])
        #expect(resolve("switch to slack", running) == .action(.app(slack)))
        #expect(resolve("open slack", running) == .action(.app(slack)))
    }

    @Test func runningAppsKeepTheirForgivingMatchesWhenSwitching() {
        let code = App(name: "Visual Studio Code", bundleId: "com.microsoft.VSCode")
        #expect(resolve("switch to studio", catalog(running: [code])) == .action(.app(code)))
        #expect(resolve("switch to code visual", catalog(running: [code])) == .action(.app(code)))
        #expect(resolve("switch to ghosty", catalog(running: [ghostty])) == .action(.app(ghostty)))
    }

    @Test func aClosedAppIsNeverGuessedWhenSwitching() {
        let studio = App(name: "Android Studio", bundleId: "com.google.android.studio")
        #expect(resolve("switch to studio", catalog(installed: [studio])) == .noMatch("studio"))
        #expect(resolve("switch to ghosty", catalog(installed: [ghostty])) == .noMatch("ghosty"))
        #expect(resolve("switch to ghostty term", catalog(installed: [ghostty])) == .noMatch("ghostty term"))
        #expect(resolve("open studio", catalog(installed: [studio])) == .action(.app(studio)))
        #expect(resolve("open ghosty", catalog(installed: [ghostty])) == .action(.app(ghostty)))
    }

    @Test func aClosedNearMissCannotTakeAPhraseFromSomethingOpen() {
        let notes = window("Ghostty Notes", app: chrome)
        let both = catalog(running: [chrome], installed: [chrome, ghostty], windows: [notes])
        #expect(resolve("open ghosty", both) == .action(.app(ghostty)))
        #expect(resolve("switch to ghosty", both) == .action(.window(notes)))
    }

    @Test func aClosedPartialMatchCannotTakeAPhraseFromAWindow() {
        let studio = App(name: "Android Studio", bundleId: "com.google.android.studio")
        let doc = window("Studio Notes", app: chrome)
        let both = catalog(running: [chrome], installed: [studio], windows: [doc])
        #expect(resolve("switch to studio", both) == .action(.window(doc)))
    }

    @Test func anExactlyNamedClosedAppIsExplainedBeforeAnyWindowIsGuessed() {
        let download = window("Download Slack", app: chrome)
        #expect(resolve("switch to slack", catalog(running: [chrome], installed: [slack], windows: [download]))
                == .closed(.app(bundleId: slack.bundleId, say: "open Slack", find: nil)))
    }

    @Test func aRunningPartialMatchStillOutranksAnExactClosedApp() {
        let helper = App(name: "Slack Helper", bundleId: "com.example.slackhelper")
        let both = catalog(running: [helper], installed: [slack, helper])
        #expect(resolve("switch to slack", both) == .action(.app(helper)))
        #expect(resolve("open slack", both) == .action(.app(helper)))
    }

    @Test func aSavedLinkWithNoOpenTabCannotTakeAPhraseFromAnOpenWindow() {
        let team = VoiceCommandPlace(name: "Team Dashboard", target: .url("https://dash.example.com/"))
        let board = window("Dashboard", app: chrome)
        #expect(resolve("switch to dashboard", catalog(places: [team], running: [chrome], tabs: [], windows: [board]))
                == .action(.window(board)))
        #expect(resolve("switch to dashboard", catalog(places: [team], running: [chrome], tabs: nil, windows: [board]))
                == .needsTabs(browser: nil))
        let open = Tab(browserBundleId: chrome.bundleId, window: 1, tab: 2, url: "https://dash.example.com/a", title: "A")
        #expect(resolve("switch to dashboard", catalog(places: [team], running: [chrome], tabs: [open], windows: [board]))
                == .action(.place(team, .tab(open))))
        #expect(resolve("open dashboard", catalog(places: [team], running: [chrome], tabs: [], windows: [board]))
                == .action(.place(team, .openURL("https://dash.example.com/", browser: nil))))
        let link = VoiceCommandPlace(name: "Team Chat", target: .url("slack://channel?team=T1&id=C1"))
        let chat = window("Chat", app: chrome)
        #expect(resolve("switch to chat", catalog(places: [link], running: [chrome], tabs: [], windows: [chat]))
                == .action(.window(chat)))
    }

    @Test func aScopedClosedAppKeepsTheWholePhrase() {
        let scoped = catalog(installed: [slack], findsInApps: true)
        #expect(resolve("switch to slack general", scoped)
                == .closed(.app(bundleId: slack.bundleId, say: "open Slack general", find: "general")))
        #expect(resolve("open slack general", scoped) == .needsSidebar(slack.bundleId))
    }

    @Test func aClosedBrowserIsNotStartedToSearchItsTabs() {
        let scoped = catalog(installed: [chrome], tabs: nil, findsInApps: true)
        #expect(resolve("switch to google chrome github", scoped)
                == .closed(.app(bundleId: chrome.bundleId, say: "open Google Chrome github", find: "github")))
        #expect(resolve("open google chrome github", scoped) == .needsTabs(browser: chrome.bundleId))
    }

    @Test func aSavedNameForAClosedAppFollowsTheVerb() {
        let notebook = VoiceCommandPlace(name: "Notebook", target: .app(bundleId: notes.bundleId))
        let saved = catalog(places: [notebook], installed: [notes])
        #expect(resolve("switch to notebook", saved) == .closed(.app(bundleId: notes.bundleId, say: "open Notebook", find: nil)))
        #expect(resolve("open notebook", saved) == .action(.place(notebook, .app(bundleId: notes.bundleId))))
        #expect(resolve("notebook", saved) == .action(.place(notebook, .app(bundleId: notes.bundleId))))
        let running = catalog(places: [notebook], running: [notes], installed: [notes])
        #expect(resolve("switch to notebook", running) == .action(.place(notebook, .app(bundleId: notes.bundleId))))
    }

    @Test func aSavedNameForAClosedAppIsNeverGuessedWhenSwitching() {
        let notebook = VoiceCommandPlace(name: "Work Notebook", target: .app(bundleId: notes.bundleId))
        #expect(resolve("switch to notebook", catalog(places: [notebook], installed: [notes])) == .noMatch("notebook"))
        #expect(resolve("open notebook", catalog(places: [notebook], installed: [notes]))
                == .action(.place(notebook, .app(bundleId: notes.bundleId))))
    }

    @Test func aSavedNicknameScopesToItsClosedAppWithTheWholePhrase() {
        let work = VoiceCommandPlace(name: "Work", target: .app(bundleId: slack.bundleId))
        #expect(resolve("switch to work general", catalog(places: [work], installed: [slack], findsInApps: true))
                == .closed(.app(bundleId: slack.bundleId, say: "open Work general", find: "general")))
    }

    @Test func aSavedLinkIsOnlyReusedWhenSwitching() {
        let dashboard = VoiceCommandPlace(name: "Dashboard", target: .url("https://dash.example.com/"))
        let open = Tab(browserBundleId: chrome.bundleId, window: 1, tab: 3, url: "https://dash.example.com/today", title: "Today")
        #expect(resolve("switch to dashboard", catalog(places: [dashboard], tabs: [open])) == .action(.place(dashboard, .tab(open))))
        #expect(resolve("switch to dashboard", catalog(places: [dashboard], tabs: []))
                == .closed(.link(say: "open Dashboard", checkedTabs: true)))
        #expect(resolve("open dashboard", catalog(places: [dashboard], tabs: []))
                == .action(.place(dashboard, .openURL("https://dash.example.com/", browser: nil))))
        #expect(resolve("dashboard", catalog(places: [dashboard], tabs: []))
                == .action(.place(dashboard, .openURL("https://dash.example.com/", browser: nil))))
    }

    @Test func aTabSearchDoesNotStartItsClosedBrowserWhenSwitching() {
        let tabsPlace = VoiceCommandPlace(name: "Chrome", target: .tabSearch, browser: chrome.bundleId)
        let closed = catalog(places: [tabsPlace], installed: [chrome], tabs: nil)
        #expect(VoiceCommandResolver.resolve(.place(tabsPlace), text: "inbox", reach: .running, catalog: closed)
                == .closed(.app(bundleId: chrome.bundleId, say: "open Chrome inbox", find: "inbox")))
        #expect(VoiceCommandResolver.resolve(.place(tabsPlace), text: "", reach: .running, catalog: closed)
                == .closed(.app(bundleId: chrome.bundleId, say: "open Chrome", find: nil)))
        #expect(VoiceCommandResolver.resolve(.place(tabsPlace), text: "inbox", reach: .opening, catalog: closed)
                == .needsTabs(browser: chrome.bundleId))
    }

    @Test func aCompleteSavedPhraseStillOverridesTheBuiltInVerb() {
        let work = VoiceCommandScript(name: "switch to work", run: ["/bin/work"])
        #expect(resolve("switch to work", catalog(scripts: [work], installed: [slack])) == .action(.script(work, arguments: [])))
        #expect(VoiceCommandResolver.reach("switch to work", catalog: catalog(scripts: [work])) == .opening)
        #expect(VoiceCommandResolver.reach("switch to slack", catalog: catalog(scripts: [work])) == .running)
    }

    @Test func aChoiceRemembersHowItWasAsked() {
        let notesA = App(name: "Notes Alpha", bundleId: "com.example.a")
        let notesB = App(name: "Notes Beta", bundleId: "com.example.b")
        guard case .ambiguous(let switching) = resolve("switch to notes", catalog(running: [notesA, notesB])),
              case .ambiguous(let opening) = resolve("open notes", catalog(installed: [notesA, notesB])) else {
            Issue.record("expected two choices"); return
        }
        #expect(switching.reach == .running)
        #expect(opening.reach == .opening)
        #expect(VoiceCommandResolver.resolve(.app(notesB), text: "", reach: .running, catalog: catalog(running: [notesA]))
                == .closed(.app(bundleId: notesB.bundleId, say: "open Notes Beta", find: nil)))
    }
}
