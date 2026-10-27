import Testing
@testable import KeyScribeKit

struct VoiceCommandSidebarTests {
    private typealias Item = VoiceCommandCatalog.SidebarItem
    private typealias App = VoiceCommandCatalog.App

    private let slackId = "com.tinyspeck.slackmacgap"
    private let chromeId = "com.google.Chrome"
    private let safariId = "com.apple.Safari"
    private var slackApp: App { App(name: "Slack", bundleId: slackId) }
    private var work: VoiceCommandPlace { VoiceCommandPlace(name: "Work", target: .app(bundleId: slackId)) }

    private func item(_ name: String, in section: String? = nil, at path: [Int] = [0]) -> Item {
        Item(bundleId: slackId, pid: 42, name: name, section: section, path: path)
    }

    private func catalog(
        places: [VoiceCommandPlace] = [], running: [App]? = nil, installed: [App] = [], items: [Item]? = nil,
        tabs: [VoiceCommandCatalog.Tab]? = nil, findsInApps: Bool = true
    ) -> VoiceCommandCatalog {
        var catalog = VoiceCommandCatalog(
            places: places, runningApps: running ?? [slackApp], installedApps: installed, tabs: tabs, windows: .complete([]))
        catalog.sidebarItems = items
        catalog.findsInApps = findsInApps
        catalog.tabBrowsers = [chromeId, safariId]
        return catalog
    }

    private func resolve(
        _ transcript: String, places: [VoiceCommandPlace] = [], items: [Item]?, findsInApps: Bool = true
    ) -> VoiceCommandResolution {
        VoiceCommandResolver.resolve(
            transcript, catalog: catalog(places: places, items: items, findsInApps: findsInApps))
    }

    @Test func anAppNameFollowedByMoreWordsReadsThatAppsSidebar() {
        #expect(resolve("open slack general", items: nil) == .needsSidebar(slackId))
        #expect(resolve("switch to slack general", items: nil) == .needsSidebar(slackId))
    }

    @Test func aListedItemIsOpened() {
        let general = item("general", in: "Channels", at: [1, 0, 0])
        #expect(resolve("open slack general", items: [item("Threads"), general]) == .action(.sidebarItem(general)))
    }

    @Test func anOpenWindowOfThatAppIsFoundBeforeItsSidebar() {
        let budget = VoiceCommandCatalog.Window(bundleId: slackId, appName: "Slack", pid: 42, id: "1", title: "budget \u{2014} Slack")
        let other = VoiceCommandCatalog.Window(bundleId: "com.apple.Notes", appName: "Notes", pid: 7, id: "2", title: "general")
        var withWindows = catalog(items: nil)
        withWindows.windows = .complete([other, budget])
        #expect(VoiceCommandResolver.resolve("open slack budget", catalog: withWindows) == .action(.window(budget)))
        #expect(VoiceCommandResolver.resolve("open slack general", catalog: withWindows) == .needsSidebar(slackId))
        var unread = catalog(items: nil)
        unread.windows = nil
        #expect(VoiceCommandResolver.resolve("open slack budget", catalog: unread) == .needsWindows)
        unread.windows = .needsAccessibility
        #expect(VoiceCommandResolver.resolve("open slack budget", catalog: unread) == .needsSidebar(slackId))
    }

    @Test func theAppNameAloneStillBringsTheAppForward() {
        #expect(resolve("open slack", items: nil) == .action(.app(slackApp)))
    }

    @Test func nothingIsSearchedInsideAppsWhileTheFeatureIsOff() {
        #expect(VoiceCommandResolver.resolve("open slack general", catalog: catalog(tabs: [], findsInApps: false))
                == .noMatch("slack general"))
        #expect(resolve("work general", places: [work], items: nil, findsInApps: false) == .takesNoText("Work"))
    }

    @Test func aSavedAppNicknameSearchesThatApp() {
        let general = item("general")
        #expect(resolve("work general", places: [work], items: nil) == .needsSidebar(slackId))
        #expect(resolve("work general", places: [work], items: [general]) == .action(.sidebarItem(general)))
        #expect(resolve("open work general", places: [work], items: [general]) == .action(.sidebarItem(general)))
        #expect(resolve("work", places: [work], items: nil) == .action(.place(work, .app(bundleId: slackId))))
    }

    @Test func aNicknameWinsOverAnInstalledAppWithTheSameName() {
        let textEdit = "com.apple.TextEdit"
        let sublime = VoiceCommandPlace(name: "Sublime", target: .app(bundleId: textEdit))
        let realSublime = App(name: "Sublime", bundleId: "com.sublimetext.4")
        let resolved = VoiceCommandResolver.resolve(
            "open sublime notes", catalog: catalog(places: [sublime], running: [realSublime]))
        #expect(resolved == .needsSidebar(textEdit))
    }

    @Test func theLongestAppNameSetsTheScope() {
        let code = App(name: "Visual Studio Code", bundleId: "com.microsoft.VSCode")
        let visual = App(name: "Visual", bundleId: "com.example.visual")
        let resolved = VoiceCommandResolver.resolve(
            "open visual studio code readme", catalog: catalog(running: [visual, code]))
        #expect(resolved == .needsSidebar("com.microsoft.VSCode"))
    }

    @Test func anAppNameScopesTheSearchBeforeALooserMatchOnTheWholePhrase() {
        let mail = App(name: "Mail", bundleId: "com.apple.mail")
        let helper = App(name: "Mail Inbox Helper", bundleId: "com.example.helper")
        #expect(VoiceCommandResolver.resolve("open mail inbox", catalog: catalog(running: [mail, helper]))
                == .needsSidebar("com.apple.mail"))
        let wholeName = App(name: "Mail Inbox", bundleId: "com.example.inbox")
        #expect(VoiceCommandResolver.resolve("open mail inbox", catalog: catalog(running: [mail, helper], installed: [wholeName]))
                == .action(.app(wholeName)))
    }

    @Test func appsSharingANameAskWhichOneBeforeReadingAnything() {
        let notes = App(name: "Notes", bundleId: "com.apple.Notes")
        let other = App(name: "Notes", bundleId: "com.example.notes")
        guard case .ambiguous(let choice) = VoiceCommandResolver.resolve(
            "open notes groceries", catalog: catalog(running: [notes, other]))
        else { Issue.record("expected a choice"); return }
        #expect(choice.candidates == [.app(notes), .app(other)])
        #expect(choice.text == "groceries")
    }

    @Test func choosingAnAppSearchesItForTheRestOfThePhrase() {
        let notes = App(name: "Notes", bundleId: "com.apple.Notes")
        #expect(VoiceCommandResolver.resolve(.app(notes), text: "groceries", reach: .opening, catalog: catalog()) == .needsSidebar("com.apple.Notes"))
        #expect(VoiceCommandResolver.resolve(.app(notes), text: "", reach: .opening, catalog: catalog()) == .action(.app(notes)))
    }

    @Test func aBrowserIsSearchedByItsOpenTabs() {
        let chrome = App(name: "Google Chrome", bundleId: chromeId, spokenNames: ["Google Chrome", "Chrome"])
        let inChrome = VoiceCommandCatalog.Tab(browserBundleId: chromeId, window: 1, tab: 2, url: "https://slashdot.org", title: "Slashdot")
        let inSafari = VoiceCommandCatalog.Tab(browserBundleId: safariId, window: 1, tab: 1, url: "https://slashdot.org", title: "Slashdot")
        #expect(VoiceCommandResolver.resolve("open chrome slashdot", catalog: catalog(running: [chrome]))
                == .needsTabs(browser: chromeId))
        #expect(VoiceCommandResolver.resolve("open chrome slashdot", catalog: catalog(running: [chrome], tabs: [inSafari, inChrome]))
                == .action(.tab(inChrome)))
        #expect(VoiceCommandResolver.resolve("open chrome weather", catalog: catalog(running: [chrome], tabs: [inChrome]))
                == .noTabMatch("weather", browser: chromeId))
    }

    @Test func namesAreMatchedLoosely() {
        let ana = item("Ana Diaz", in: "Direct Messages", at: [2, 0, 0])
        let release = item("release-engineering", in: "Channels", at: [1, 0, 0])
        #expect(resolve("open slack ana", items: [ana, release]) == .action(.sidebarItem(ana)))
        #expect(resolve("open slack diaz ana", items: [ana, release]) == .action(.sidebarItem(ana)))
        #expect(resolve("open slack release engineering", items: [ana, release]) == .action(.sidebarItem(release)))
        #expect(resolve("open slack releese engineering", items: [ana, release]) == .action(.sidebarItem(release)))
        #expect(resolve("open slack release engineer ing", items: [ana, release]) == .action(.sidebarItem(release)))
    }

    @Test func duplicateNamesOpenTheFirstInSidebarOrder() {
        let channel = item("design", in: "Channels", at: [1, 0, 0])
        let person = item("design", in: "Apps", at: [3, 0, 0])
        #expect(resolve("open slack design", items: [channel, person]) == .action(.sidebarItem(channel)))
    }

    @Test func nothingListedIsReported() {
        #expect(resolve("open slack payroll", items: [item("general")]) == .noSidebarMatch("payroll", app: slackId))
    }

    @Test func anOldSidebarCommandLoadsAsAnAppCommand() throws {
        let toml = """
        schema_version = 1

        [[command]]
        name = "Work"
        say = ["chat"]
        sidebar = "\(slackId)"
        """
        let config = try VoiceCommandStore.decode(from: toml)
        #expect(config.places == [VoiceCommandPlace(name: "Work", say: ["chat"], target: .app(bundleId: slackId))])
        #expect(VoiceCommandStore.unknownKeys(in: toml).isEmpty)
        let rewritten = try VoiceCommandStore.encode(config)
        #expect(rewritten.contains("app = '\(slackId)'"))
        #expect(!rewritten.contains("sidebar"))
    }

    @Test func anOldSidebarCommandStillNamesOnlyOneTarget() {
        let toml = """
        schema_version = 1

        [[command]]
        name = "Work"
        app = "com.apple.mail"
        sidebar = "\(slackId)"
        """
        #expect(throws: ConfigError.self) { try VoiceCommandStore.decode(from: toml) }
    }

    @Test func aNicknameThatHidesAnInstalledAppIsFlagged() {
        let sublime = VoiceCommandPlace(name: "Sublime", target: .app(bundleId: "com.apple.TextEdit"))
        let installed = [App(name: "Sublime Text", bundleId: "com.sublimetext.4", spokenNames: ["Sublime Text", "Sublime"])]
        #expect(VoiceCommandConfig.hiddenApps(by: .place(sublime), installed: installed)
                == ["\u{201C}Sublime\u{201D} is also the name of Sublime Text, so saying it opens this command instead."])
        let ownApp = VoiceCommandPlace(name: "Sublime", target: .app(bundleId: "com.sublimetext.4"))
        #expect(VoiceCommandConfig.hiddenApps(by: .place(ownApp), installed: installed).isEmpty)
    }
}
