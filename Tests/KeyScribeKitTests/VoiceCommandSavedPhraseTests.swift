import Testing
@testable import KeyScribeKit

struct VoiceCommandSavedPhraseTests {
    private typealias Tab = VoiceCommandCatalog.Tab

    private let chromeId = "com.google.Chrome"
    private let braveId = "com.brave.Browser"

    private func resolve(
        _ transcript: String, places: [VoiceCommandPlace] = [], scripts: [VoiceCommandScript] = [],
        running: [VoiceCommandCatalog.App] = [], tabs: [Tab]? = [], windows: VoiceCommandCatalog.WindowScan? = .complete([])
    ) -> VoiceCommandResolution {
        VoiceCommandResolver.resolve(transcript, catalog: VoiceCommandCatalog(
            places: places, scripts: scripts, runningApps: running, tabs: tabs, windows: windows))
    }

    private func script(_ name: String, say: [String] = []) -> VoiceCommandScript {
        VoiceCommandScript(name: name, say: say, run: ["/bin/\(name.lowercased())", "{text}"])
    }

    private func tab(_ title: String, in browser: String, tab: Int = 1) -> Tab {
        Tab(browserBundleId: browser, window: 1, tab: tab, url: "https://example.com/\(tab)", title: title)
    }

    @Test func aSavedActionRunsByItsNameAndRunStillWorks() {
        let note = script("Note")
        #expect(resolve("note buy milk", scripts: [note]) == .action(.script(note, arguments: ["buy milk"])))
        #expect(resolve("run note buy milk", scripts: [note]) == .action(.script(note, arguments: ["buy milk"])))
    }

    @Test(arguments: ["go home", "open notes", "focus mode", "launch pad", "switch to work"])
    func aNaturalPhraseIsANameLikeAnyOther(_ phrase: String) {
        let place = VoiceCommandPlace(name: phrase, target: .app(bundleId: "com.example.a"))
        let action = VoiceCommandScript(name: phrase, run: ["/bin/a"])
        #expect(place.issue == nil)
        #expect(action.issue == nil)
        #expect(resolve(phrase, places: [place]) == .action(.place(place, .app(bundleId: "com.example.a"))))
        #expect(resolve(phrase, scripts: [action]) == .action(.script(action, arguments: [])))
    }

    @Test func aSavedPhraseTakesPrecedenceOverTheVerbItStartsWith() {
        let notes = VoiceCommandPlace(name: "Open notes", target: .app(bundleId: "com.example.notes"))
        let mail = VoiceCommandCatalog.App(name: "Mail", bundleId: "com.apple.mail")
        #expect(resolve("open notes", places: [notes]) == .action(.place(notes, .app(bundleId: "com.example.notes"))))
        #expect(resolve("open mail", places: [notes], running: [mail]) == .action(.app(mail)))
    }

    @Test(arguments: [false, true])
    func theLongestPhraseWinsWhicheverIsListedFirst(_ reversed: Bool) {
        let note = script("Note")
        let work = script("Note work")
        let scripts = reversed ? [work, note] : [note, work]
        #expect(resolve("note work buy milk", scripts: scripts) == .action(.script(work, arguments: ["buy milk"])))
        #expect(resolve("note buy milk", scripts: scripts) == .action(.script(note, arguments: ["buy milk"])))
    }

    @Test func aLongerPhraseThatNeedsWordsNeverFallsBackToTheShorterOne() {
        let slack = script("Slack")
        let joe = script("Slack Joe")
        #expect(resolve("slack joe", scripts: [slack, joe]) == .scriptNeedsText("Slack Joe"))
    }

    @Test func aLongerPhraseWithoutWordsSaysSoInsteadOfRunningTheShorterOne() {
        let slack = script("Slack")
        let joe = VoiceCommandScript(name: "Slack Joe", run: ["/bin/joe"])
        #expect(resolve("slack joe about lunch", scripts: [slack, joe]) == .takesNoText("Slack Joe"))
        #expect(resolve("run slack joe about lunch", scripts: [slack, joe]) == .takesNoText("Slack Joe"))
        #expect(resolve("slack joe", scripts: [slack, joe]) == .action(.script(joe, arguments: [])))
    }

    @Test func aPlaceSaysItTakesNoWords() {
        let channel = VoiceCommandPlace(
            name: "Webhooks and Callbacks", say: ["web hooks"], target: .url("slack://channel?team=T1&id=C1"))
        #expect(resolve("Web hooks.", places: [channel])
                == .action(.place(channel, .openURL("slack://channel?team=T1&id=C1", browser: nil))))
        #expect(resolve("webhooks", places: [channel]) == .notACommand)
        #expect(resolve("open web hooks", places: [channel])
                == .action(.place(channel, .openURL("slack://channel?team=T1&id=C1", browser: nil))))
        #expect(resolve("web hooks please", places: [channel]) == .takesNoText("Webhooks and Callbacks"))
    }

    @Test func aSavedWebPlaceReadsTabsFirst() {
        let gmail = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"))
        #expect(resolve("gmail", places: [gmail], tabs: nil) == .needsTabs(browser: nil))
    }

    @Test func aTabSearchLooksOnlyInItsBrowser() {
        let chrome = VoiceCommandPlace(name: "Chrome", target: .tabSearch, browser: chromeId)
        let inChrome = tab("Inbox (3) - Gmail", in: chromeId, tab: 2)
        let inBrave = tab("Gmail", in: braveId, tab: 1)
        #expect(resolve("chrome gmail", places: [chrome], tabs: nil) == .needsTabs(browser: chromeId))
        #expect(resolve("chrome gmail", places: [chrome], tabs: [inBrave, inChrome]) == .action(.tab(inChrome)))
        #expect(resolve("chrome gmail", places: [chrome], tabs: [inBrave]) == .noTabMatch("gmail", browser: chromeId))
    }

    @Test func aTabSearchMatchesTitlesLoosely() {
        let chrome = VoiceCommandPlace(name: "Chrome", target: .tabSearch, browser: chromeId)
        let run = tab("Afternoon Run | Run | Strava", in: chromeId, tab: 3)
        #expect(resolve("Chrome, strava run.", places: [chrome], tabs: [tab("Inbox", in: chromeId), run]) == .action(.tab(run)))
        #expect(resolve("chrome stravva", places: [chrome], tabs: [tab("Inbox", in: chromeId), run]) == .action(.tab(run)))
    }

    @Test func aTabSearchForAnyBrowserLooksEverywhere() {
        let tabs = VoiceCommandPlace(name: "Tab", target: .tabSearch)
        let inBrave = tab("Home Assistant", in: braveId)
        #expect(resolve("tab home assistant", places: [tabs], tabs: nil) == .needsTabs(browser: nil))
        #expect(resolve("tab home assistant", places: [tabs], tabs: [inBrave]) == .action(.tab(inBrave)))
    }

    @Test func aTabSearchSaidAloneBringsItsBrowserForward() {
        let chrome = VoiceCommandPlace(name: "Chrome", target: .tabSearch, browser: chromeId)
        #expect(resolve("chrome", places: [chrome]) == .action(.place(chrome, .app(bundleId: chromeId))))
        let any = VoiceCommandPlace(name: "Tab", target: .tabSearch)
        #expect(resolve("tab", places: [any]) == .scriptNeedsText("Tab"))
    }

    @Test func switchingToTheBrowsersNameStillOpensTheBrowser() {
        let chrome = VoiceCommandPlace(name: "Chrome", target: .tabSearch, browser: chromeId)
        let app = VoiceCommandCatalog.App(name: "Google Chrome", bundleId: chromeId)
        #expect(resolve("switch to chrome", places: [chrome], running: [app]) == .action(.app(app)))
    }

    @Test func equalPhrasesAcrossKindsAskWhichOne() throws {
        let place = VoiceCommandPlace(name: "Deploy Docs", say: ["deploy"], target: .url("https://docs.example.com/"))
        let deploy = VoiceCommandScript(name: "Deploy", run: ["/bin/deploy"])
        guard case .ambiguous(let choice) = resolve("deploy", places: [place], scripts: [deploy]) else {
            Issue.record("expected a choice"); return
        }
        #expect(choice.candidates == [.place(place), .script(deploy)])
        #expect(choice.family == .navigation)
    }

    @Test func aTabSearchCannotBeAnAppLinkOrApp() throws {
        let toml = """
        schema_version = 1
        [[command]]
        name = "Chrome"
        find_tab = true
        app = "com.google.Chrome"
        """
        #expect(throws: (any Error).self) { try VoiceCommandStore.decode(from: toml) }
    }

    @Test func tabSearchRoundTripsThroughTOML() throws {
        let config = VoiceCommandConfig(
            places: [
                VoiceCommandPlace(name: "Chrome", target: .tabSearch, browser: chromeId),
                VoiceCommandPlace(name: "Hooks", target: .url("slack://open")),
                VoiceCommandPlace(name: "Mail", target: .app(bundleId: "com.apple.mail")),
            ],
            scripts: [script("Note")])
        let toml = try VoiceCommandStore.encode(config)
        #expect(try VoiceCommandStore.decode(from: toml) == config)
        #expect(VoiceCommandStore.unknownKeys(in: toml).isEmpty)
    }
}

struct VoiceCommandIdentityTests {
    @Test func everyKindOfCommandMatchesItsPhraseTheSameWay() {
        let place = VoiceCommandPlace(name: "Web hooks", target: .url("slack://open"))
        let script = VoiceCommandScript(name: "Web hooks", run: ["/bin/hooks"])
        let catalog = { (places: [VoiceCommandPlace], scripts: [VoiceCommandScript]) in
            VoiceCommandCatalog(places: places, scripts: scripts, tabs: [], windows: .complete([]))
        }
        #expect(VoiceCommandResolver.savedMatch("webhooks", catalog: catalog([place], [])) == nil)
        #expect(VoiceCommandResolver.savedMatch("webhooks", catalog: catalog([], [script])) == nil)
        #expect(VoiceCommandResolver.savedMatch("web hooks", catalog: catalog([place], []))?.candidates == [.place(place)])
        #expect(VoiceCommandResolver.savedMatch("web hooks", catalog: catalog([], [script]))?.candidates == [.script(script)])
    }

    @Test func commandsKeepOneOrderAndTheirIdsInTheFile() throws {
        let config = VoiceCommandConfig(commands: [
            .script(VoiceCommandScript(id: "s1", name: "Note", run: ["/bin/note", "{text}"])),
            .place(VoiceCommandPlace(id: "p1", name: "Mail", target: .app(bundleId: "com.apple.mail"))),
            .script(VoiceCommandScript(id: "s2", name: "Journal", shortcut: .init(name: "Journal", input: "{text}"))),
            .place(VoiceCommandPlace(id: "p2", name: "Chrome", target: .tabSearch, browser: "com.google.Chrome")),
        ])
        let toml = try VoiceCommandStore.encode(config)
        #expect(toml.components(separatedBy: "[[command]]").count == 5)
        #expect(try VoiceCommandStore.decode(from: toml) == config)
        #expect(VoiceCommandStore.unknownKeys(in: toml).isEmpty)
    }

    @Test func aCommandWrittenWithoutAnIdGetsOneFromItsName() throws {
        let config = try VoiceCommandStore.decode(from: """
        schema_version = 1
        [[command]]
        name = "Work Mail"
        app = "com.apple.mail"
        """)
        #expect(config.commands.map(\.id) == ["work-mail"])
    }

    @Test(arguments: [
        "app = \"com.apple.mail\"\nrun = [\"/bin/x\"]",
        "run = [\"/bin/x\"]\nbrowser = \"com.google.Chrome\"",
        "url = \"https://a.example/\"\ninput = \"{text}\"",
        "say = [\"x\"]",
    ])
    func aCommandMustDoExactlyOneThing(_ body: String) {
        #expect(throws: (any Error).self) {
            try VoiceCommandStore.decode(from: "schema_version = 1\n[[command]]\nname = \"X\"\n\(body)\n")
        }
    }

    @Test func twoCommandsCannotShareAnId() {
        let config = VoiceCommandConfig(commands: [
            .place(VoiceCommandPlace(id: "same", name: "Mail", target: .app(bundleId: "com.apple.mail"))),
            .script(VoiceCommandScript(id: "same", name: "Note", run: ["/bin/note"])),
        ])
        #expect(config.issue == "command \"Note\": another command already uses the id \"same\"")
    }

    @Test func aChoiceStillResolvesAfterTheCommandIsRenamed() {
        let deploy = VoiceCommandScript(id: "d1", name: "Deploy", run: ["/bin/deploy", "{text}"])
        var renamed = deploy
        renamed.name = "Release"
        let catalog = VoiceCommandCatalog(scripts: [renamed])
        #expect(VoiceCommandResolver.resolve(.script(deploy), text: "prod", reach: .opening, catalog: catalog)
                == .action(.script(renamed, arguments: ["prod"])))
        var changed = renamed
        changed.action = .program(["/bin/other", "{text}"])
        #expect(VoiceCommandResolver.resolve(.script(deploy), text: "prod", reach: .opening, catalog: VoiceCommandCatalog(scripts: [changed]))
                == .unavailable("Deploy"))
    }
}

struct VoiceCommandConflictTests {
    private let mail = VoiceCommandPlace(name: "Mail", target: .app(bundleId: "com.apple.mail"))

    @Test func aPhraseSharedWithAnotherKindAsksAndSaysSo() {
        let config = VoiceCommandConfig(places: [mail])
        let script = VoiceCommandScript(name: "Mailer", say: ["mail"], run: ["/bin/mailer"])
        #expect(config.conflicts(for: .script(script))
                == ["\u{201C}mail\u{201D} is also a name for Mail, so saying it will ask you to choose. Give this one a name of its own."])
    }

    @Test func aCommandDoesNotConflictWithItsOwnSavedCopy() {
        let config = VoiceCommandConfig(places: [mail])
        var renamed = mail
        renamed.say = ["inbox"]
        #expect(config.conflicts(for: .place(renamed)).isEmpty)
    }

    @Test func aLongerSavedPhraseThatTakesOverSomeWordsIsExplained() {
        let joe = VoiceCommandScript(name: "Slack Joe", run: ["/bin/joe"])
        let slack = VoiceCommandScript(name: "Slack", run: ["/bin/slack", "{text}"])
        #expect(VoiceCommandConfig(scripts: [joe]).conflicts(for: .script(slack))
                == ["\u{201C}Slack Joe\u{201D} runs Slack Joe instead, because its name is longer."])
        let bare = VoiceCommandScript(name: "Slack", run: ["/bin/slack"])
        #expect(VoiceCommandConfig(scripts: [joe]).conflicts(for: .script(bare)).isEmpty)
    }

    @Test func addingALongerPhraseExplainsWhatItTakesFromAnExistingCommand() {
        let note = VoiceCommandScript(name: "Note", run: ["/bin/note", "{text}"])
        let work = VoiceCommandScript(name: "Note work", run: ["/bin/work", "{text}"])
        #expect(VoiceCommandConfig(scripts: [note]).conflicts(for: .script(work))
                == ["Saying \u{201C}Note work \u{2026}\u{201D} will run this command instead of Note, because its name is longer."])
        let board = VoiceCommandPlace(name: "Note board", target: .app(bundleId: "com.example.board"))
        #expect(VoiceCommandConfig(scripts: [note]).conflicts(for: .place(board))
                == ["Saying \u{201C}Note board\u{201D} will run this command instead of Note, because its name is longer."])
        let ping = VoiceCommandScript(name: "Ping", run: ["/bin/ping"])
        let pingAll = VoiceCommandScript(name: "Ping all", run: ["/bin/ping-all"])
        #expect(VoiceCommandConfig(scripts: [ping]).conflicts(for: .script(pingAll)).isEmpty)
    }

    @Test func aPhraseThatCoversABuiltInCommandIsExplained() {
        let go = VoiceCommandScript(name: "Go", run: ["/bin/go", "{text}"])
        #expect(VoiceCommandConfig().conflicts(for: .script(go))
                == ["Saying \u{201C}go back\u{201D} will run this command instead of returning to the previous window."])
        let open = VoiceCommandPlace(name: "Open", target: .app(bundleId: "com.example.open"))
        #expect(VoiceCommandConfig().conflicts(for: .place(open))
                == ["Saying \u{201C}open \u{2026}\u{201D} will reach this command instead of opening an app or place."])
        let switchTo = VoiceCommandPlace(name: "Switch to", target: .app(bundleId: "com.example.switch"))
        #expect(VoiceCommandConfig().conflicts(for: .place(switchTo))
                == ["Saying \u{201C}switch to \u{2026}\u{201D} will reach this command instead of switching to an open app or place."])
        let run = VoiceCommandScript(name: "Run", run: ["/bin/run"])
        #expect(VoiceCommandConfig().conflicts(for: .script(run))
                == ["Saying \u{201C}run \u{2026}\u{201D} will reach this command instead of your other actions."])
    }

    @Test(arguments: ["go home", "open notes", "focus mode", "Mail"])
    func aPhraseThatOnlyStartsLikeABuiltInIsFine(_ phrase: String) {
        let place = VoiceCommandPlace(name: phrase, target: .app(bundleId: "com.example.a"))
        #expect(VoiceCommandConfig().conflicts(for: .place(place)).isEmpty)
    }
}

struct VoiceCommandExampleTests {
    @Test func aScriptExampleFollowsTheEditedSampleWords() {
        let probe = VoiceCommandScript(name: "Probe", run: ["/bin/probe", "--find", "{text}"])
        let example = VoiceCommandExample.make(for: .script(probe), sample: "  release notes  ")
        #expect(example.heard == "probe release notes")
        #expect(example.result == "Runs /bin/probe --find 'release notes' in the background.")
        #expect(example.conflict == nil)
    }

    @Test func aCustomSampleStillChecksWhichCommandWouldHearIt() {
        let note = VoiceCommandScript(name: "Note", run: ["/bin/note", "{text}"])
        let meeting = VoiceCommandScript(name: "Note meeting", run: ["/bin/meeting", "{text}"])
        let example = VoiceCommandExample.make(
            for: .script(note), sample: "meeting agenda", among: VoiceCommandConfig(scripts: [meeting]))
        #expect(example.conflict == "Saying \u{201C}note meeting agenda\u{201D} runs Note meeting instead, because its name is longer.")
    }

    @Test func anEmptySampleExplainsTheMissingSpokenInput() {
        let probe = VoiceCommandScript(name: "Probe", run: ["/bin/probe", "{text}"])
        let example = VoiceCommandExample.make(for: .script(probe), sample: "   ")
        #expect(example.heard == "probe")
        #expect(example.result.isEmpty)
        #expect(example.conflict == "Saying \u{201C}probe\u{201D} gives this command no words after its name.")
    }

    @Test func anActionExampleUsesItsOwnNameAndWords() {
        let probe = VoiceCommandScript(name: "Probe", say: ["memo"], run: ["/bin/probe", "{text}"])
        let example = VoiceCommandExample.make(for: .script(probe))
        #expect(example.heard == "probe buy milk")
        #expect(example.result == "Runs /bin/probe 'buy milk' in the background.")
        #expect(example.conflict == nil)
        let bare = VoiceCommandScript(name: "Ping", run: ["/bin/ping"])
        #expect(VoiceCommandExample.make(for: .script(bare)).heard == "ping")
    }

    @Test func aPlaceExampleNamesWhereItGoes() {
        let hooks = VoiceCommandPlace(name: "Web Hooks", target: .url("slack://channel?team=T1&id=C1"))
        let example = VoiceCommandExample.make(for: .place(hooks))
        #expect(example.heard == "web hooks")
        #expect(example.result == "Opens slack://channel?team=T1&id=C1 in the app that handles it.")
        let mail = VoiceCommandPlace(name: "Mail", target: .app(bundleId: "com.apple.mail"))
        #expect(VoiceCommandExample.make(for: .place(mail), appName: { _ in "Mail" }).heard == "mail")
    }

    @Test func aTabSearchExampleSaysWhereItLooks() {
        let chrome = VoiceCommandPlace(name: "Chrome", target: .tabSearch, browser: "com.google.Chrome")
        let example = VoiceCommandExample.make(for: .place(chrome), appName: { _ in "Google Chrome" })
        #expect(example.heard == "chrome inbox")
        #expect(example.result == "Switches to the open Google Chrome tab whose title or site best matches \u{201C}inbox\u{201D}. If several match equally, it picks the leftmost match in the frontmost window that has one.")
        let any = VoiceCommandPlace(name: "Tab", target: .tabSearch)
        #expect(VoiceCommandExample.make(for: .place(any)).result.hasSuffix(
            "frontmost window that has one. Matches in different browsers still ask."))
    }

    @Test func theExampleIsCheckedAgainstTheOtherSavedCommands() {
        let note = VoiceCommandScript(name: "Note", run: ["/bin/note", "{text}"])
        let noteBuy = VoiceCommandScript(name: "Note buy", run: ["/bin/shop", "{text}"])
        let example = VoiceCommandExample.make(for: .script(note), among: VoiceCommandConfig(scripts: [noteBuy]))
        #expect(example.conflict == "Saying \u{201C}note buy milk\u{201D} runs Note buy instead, because its name is longer.")
        let shared = VoiceCommandPlace(name: "Notes", say: ["note"], target: .app(bundleId: "com.apple.Notes"))
        let bare = VoiceCommandScript(name: "Note", run: ["/bin/note"])
        #expect(VoiceCommandExample.make(for: .script(bare), among: VoiceCommandConfig(places: [shared])).conflict
                == "Saying \u{201C}note\u{201D} would ask you to choose between this command and Notes.")
    }

    @Test func theExampleIsReadThroughReplacementsLikeALiveCommand() {
        let note = VoiceCommandScript(name: "Note", run: ["/bin/note", "{text}"])
        let shop = VoiceCommandScript(name: "Shop", run: ["/bin/shop", "{text}"])
        let saved = VoiceCommandConfig(scripts: [shop])
        let redirected = VoiceCommandExample.make(
            for: .script(note), among: saved, readAs: { $0.replacingOccurrences(of: "note", with: "shop") })
        #expect(redirected.conflict
                == "Your replacements read \u{201C}note buy milk\u{201D} as \u{201C}shop buy milk\u{201D}, so it runs Shop instead.")
        let lost = VoiceCommandExample.make(for: .script(note), readAs: { _ in "switch to mail" })
        #expect(lost.conflict
                == "Your replacements read \u{201C}note buy milk\u{201D} as \u{201C}switch to mail\u{201D}, so it does not run this command.")
        let kept = VoiceCommandExample.make(for: .script(note), readAs: { $0.replacingOccurrences(of: "milk", with: "eggs") })
        #expect(kept == VoiceCommandExample(heard: "note buy milk", result: "Runs /bin/note 'buy eggs' in the background."))
    }

    @Test func everyNameIsCheckedSoAnOtherNameARuleTakesAwayIsReported() {
        let slack = VoiceCommandScript(name: "Slack", say: ["slack unread"], run: ["/bin/slack", "{text}"])
        let jump = VoiceCommandScript(name: "Jump", run: ["/bin/jump", "{text}"])
        let saved = VoiceCommandConfig(scripts: [slack, jump])
        let readAs: (String) -> String = { $0.hasPrefix("slack unread") ? "jump " + $0 : $0 }
        #expect(VoiceCommandExample.make(for: .script(slack), among: saved, readAs: readAs).conflict == nil)
        #expect(VoiceCommandExample.namesLostToReplacements(for: .script(slack), among: saved, readAs: readAs) == [
            "Your replacements read \u{201C}slack unread buy milk\u{201D} as \u{201C}jump slack unread buy milk\u{201D}, so it runs Jump instead.",
        ])
        #expect(VoiceCommandExample.namesLostToReplacements(for: .script(slack), among: saved).isEmpty)
    }

    @Test func aRedirectToTwoOtherCommandsSaysItWouldAsk() {
        let note = VoiceCommandScript(name: "Note", run: ["/bin/note", "{text}"])
        let shop = VoiceCommandScript(name: "Shop", run: ["/bin/shop", "{text}"])
        let store = VoiceCommandScript(name: "Store", say: ["shop"], run: ["/bin/store", "{text}"])
        let example = VoiceCommandExample.make(
            for: .script(note), among: VoiceCommandConfig(scripts: [shop, store]),
            readAs: { $0.replacingOccurrences(of: "note", with: "shop") })
        #expect(example.conflict
                == "Your replacements read \u{201C}note buy milk\u{201D} as \u{201C}shop buy milk\u{201D}, so it would ask you to choose between Shop and Store.")
    }

    @Test func aReplacementThatAddsRunStillPreviewsTheSameCommand() {
        let note = VoiceCommandScript(name: "Note", run: ["/bin/note", "{text}"])
        let example = VoiceCommandExample.make(for: .script(note), readAs: { "run " + $0 })
        #expect(example == VoiceCommandExample(heard: "note buy milk", result: "Runs /bin/note 'buy milk' in the background."))
    }

    @Test func aTabSearchPreviewUsesTheWordsAfterReplacements() {
        let chrome = VoiceCommandPlace(name: "Chrome", target: .tabSearch, browser: "com.google.Chrome")
        let example = VoiceCommandExample.make(
            for: .place(chrome), readAs: { $0.replacingOccurrences(of: "inbox", with: "gmail") }, appName: { _ in "Google Chrome" })
        #expect(example.result.hasPrefix("Switches to the open Google Chrome tab whose title or site best matches \u{201C}gmail\u{201D}."))
    }

    @Test func aReplacementThatTurnsAPlaceIntoAVerbStillFindsIt() {
        let mail = VoiceCommandPlace(name: "Mail", target: .app(bundleId: "com.apple.mail"))
        let example = VoiceCommandExample.make(for: .place(mail), readAs: { "open " + $0 }, appName: { _ in "Mail" })
        #expect(example == VoiceCommandExample(heard: "mail", result: "Brings Mail to the front, opening it if needed."))
    }

    @Test func editingACommandIgnoresItsOwnSavedCopy() {
        let note = VoiceCommandScript(name: "Note", run: ["/bin/note", "{text}"])
        var edited = note
        edited.say = ["jot"]
        let example = VoiceCommandExample.make(for: .script(edited), among: VoiceCommandConfig(scripts: [note]))
        #expect(example.conflict == nil)
    }

    @Test func sayLinesShowThePhrasesThatWork() {
        let mail = VoiceCommandPlace(name: "Mail", say: ["inbox"], target: .app(bundleId: "com.apple.mail"))
        #expect(VoiceCommandExample.phrases(for: .place(mail)) == ["Mail", "inbox"])
        let chrome = VoiceCommandPlace(name: "Chrome", target: .tabSearch)
        #expect(VoiceCommandExample.phrases(for: .place(chrome)) == ["Chrome \u{2026}"])
        let note = VoiceCommandScript(name: "Note", run: ["/bin/note", "{text}"])
        #expect(VoiceCommandExample.phrases(for: .script(note)) == ["Note \u{2026}"])
    }
}
