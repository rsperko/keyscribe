import Testing
@testable import KeyScribeKit

struct VoiceCommandChoiceTests {
    private typealias App = VoiceCommandCatalog.App
    private typealias Tab = VoiceCommandCatalog.Tab

    private let personal = VoiceCommandPlace(
        name: "Personal Mail", say: ["mail"], target: .url("https://mail.example.net/u/0"), browser: "com.apple.Safari")
    private let work = VoiceCommandPlace(
        name: "Work Mail", say: ["mail"], target: .url("https://user:secret@inbox.example.org/inbox?folder=all"),
        browser: "com.google.Chrome")
    private let notes = VoiceCommandPlace(name: "Notes", say: ["mail"], target: .app(bundleId: "com.apple.Notes"))

    private func choice(_ resolution: VoiceCommandResolution) -> VoiceCommandChoice? {
        if case .ambiguous(let choice) = resolution { return choice }
        return nil
    }

    private func resolve(
        _ transcript: String, places: [VoiceCommandPlace] = [], scripts: [VoiceCommandScript] = [],
        running: [App] = [], installed: [App] = []
    ) -> VoiceCommandResolution {
        VoiceCommandResolver.resolve(transcript, catalog: VoiceCommandCatalog(
            places: places, scripts: scripts, runningApps: running, installedApps: installed))
    }

    @Test func aSharedAliasOffersTypedCandidatesInConfigurationOrder() throws {
        let offered = try #require(choice(resolve("switch to mail", places: [personal, work])))
        #expect(offered.family == .navigation)
        #expect(offered.target == "mail")
        #expect(offered.candidates == [.place(personal), .place(work)])
        #expect(offered.total == 2)
        #expect(offered.isOffered)
    }

    @Test func fiveChoicesAreOfferedButSixAreNot() throws {
        let five = (1...5).map { App(name: "Note \($0)", bundleId: "com.example.note\($0)") }
        let offered = try #require(choice(resolve("switch to note", running: five)))
        #expect(offered.candidates.count == 5)
        #expect(offered.isOffered)

        let six = five + [App(name: "Note 6", bundleId: "com.example.note6")]
        let tooMany = try #require(choice(resolve("switch to note", running: six)))
        #expect(tooMany.total == 6)
        #expect(!tooMany.isOffered)
        #expect(tooMany.tooManyMessage == "6 matches for \u{201C}note\u{201D}. Say more of the name.")
    }

    @Test func theSameAppListedTwiceCountsOnceButTwoAppsSharingANameStaySeparate() throws {
        let chrome = App(name: "Chrome", bundleId: "com.google.Chrome")
        let canary = App(name: "Chrome", bundleId: "com.google.Chrome.canary")
        let offered = try #require(choice(resolve("switch to chrome", running: [chrome, canary, chrome])))
        #expect(offered.total == 2)
        #expect(offered.candidates.map(\.identity) == ["app:com.google.Chrome", "app:com.google.Chrome.canary"])
    }

    @Test func appsAreOfferedInAStableOrderWhateverOrderTheyAreRunningIn() throws {
        let b = App(name: "Beta Notes", bundleId: "com.example.b")
        let a = App(name: "Alpha Notes", bundleId: "com.example.a")
        let first = try #require(choice(resolve("switch to notes", running: [b, a])))
        let second = try #require(choice(resolve("switch to notes", running: [a, b])))
        #expect(first.candidates == second.candidates)
        #expect(first.candidates.map(\.name) == ["Alpha Notes", "Beta Notes"])
    }

    @Test func runOffersActionsAndFreezesTheirInput() throws {
        let deploy = VoiceCommandScript(name: "Deploy", say: ["ship"], run: ["/bin/deploy", "{text}"])
        let note = VoiceCommandScript(
            name: "New Note", say: ["ship"], shortcut: VoiceCommandShortcut(name: "Make Note", input: "{text}"))
        let offered = try #require(choice(resolve("run ship staging", scripts: [deploy, note])))
        #expect(offered.family == .action)
        #expect(offered.target == "ship")
        #expect(offered.text == "staging")
        #expect(offered.candidates == [.script(deploy), .script(note)])
    }

    @Test func rowDetailsTellTheChoicesApartWithoutExposingCredentialsOrQueries() {
        let names = ["com.apple.Safari": "Safari", "com.google.Chrome": "Google Chrome", "com.apple.Notes": "Notes"]
        let appName: (String) -> String? = { names[$0] }
        let candidates: [VoiceCommandCandidate] = [.place(personal), .place(work), .place(notes)]
        #expect(candidates.map { $0.detail(appName: appName, among: candidates) }
                == ["Safari \u{00B7} mail.example.net", "Google Chrome \u{00B7} inbox.example.org", "Notes"])
        let defaultBrowser = VoiceCommandPlace(name: "Docs", target: .url("https://docs.example.com/a"))
        #expect(VoiceCommandCandidate.place(defaultBrowser).detail(appName: appName, among: [])
                == "Default browser \u{00B7} docs.example.com")
    }

    @Test func appDetailsShowTheBundleOnlyWhenNamesRepeat() {
        let chrome = VoiceCommandCandidate.app(App(name: "Chrome", bundleId: "com.google.Chrome"))
        let canary = VoiceCommandCandidate.app(App(name: "Chrome", bundleId: "com.google.Chrome.canary"))
        let code = VoiceCommandCandidate.app(App(name: "Code", bundleId: "com.microsoft.VSCode"))
        #expect(chrome.detail(appName: { _ in nil }, among: [chrome, canary]) == "com.google.Chrome")
        #expect(code.detail(appName: { _ in nil }, among: [chrome, code]) == "App")
    }

    @Test func actionDetailsNameTheKindWithoutTheInput() {
        let deploy = VoiceCommandCandidate.script(VoiceCommandScript(name: "Deploy", run: ["/usr/local/bin/deploy", "{text}"]))
        let shortcut = VoiceCommandCandidate.script(VoiceCommandScript(
            name: "Note", shortcut: VoiceCommandShortcut(name: "Make Note", input: "{text}")))
        let same = VoiceCommandCandidate.script(VoiceCommandScript(name: "Make Note", shortcut: VoiceCommandShortcut(name: "Make Note")))
        #expect(deploy.detail(appName: { _ in nil }, among: []) == "Script \u{00B7} deploy")
        #expect(shortcut.detail(appName: { _ in nil }, among: []) == "Shortcut \u{00B7} Make Note")
        #expect(same.detail(appName: { _ in nil }, among: []) == "Shortcut")
    }

    @Test func aChosenPlaceResolvesOnItsOwnAgainstTheCurrentTabs() {
        let tab = Tab(browserBundleId: "com.google.Chrome", window: 1, tab: 3, url: "https://user:secret@inbox.example.org/inbox?folder=all", title: "Inbox")
        let catalog = VoiceCommandCatalog(places: [personal, work], tabs: [tab])
        #expect(VoiceCommandResolver.resolve(.place(work), text: "", catalog: catalog) == .action(.place(work, .tab(tab))))
        #expect(VoiceCommandResolver.resolve(.place(personal), text: "", catalog: catalog)
                == .action(.place(personal, .openURL("https://mail.example.net/u/0", browser: "com.apple.Safari"))))
        #expect(VoiceCommandResolver.resolve(.place(work), text: "", catalog: VoiceCommandCatalog(places: [work]))
                == .needsTabs(browser: "com.google.Chrome"))
    }

    @Test func aChosenEntryThatWasRemovedOrRepointedIsUnavailable() {
        var moved = work
        moved.target = .url("https://elsewhere.example.org/")
        #expect(VoiceCommandResolver.resolve(.place(work), text: "", catalog: VoiceCommandCatalog(places: [personal]))
                == .unavailable("Work Mail"))
        #expect(VoiceCommandResolver.resolve(.place(work), text: "", catalog: VoiceCommandCatalog(places: [moved], tabs: []))
                == .unavailable("Work Mail"))
        let deploy = VoiceCommandScript(name: "Deploy", run: ["/bin/deploy"])
        let changed = VoiceCommandScript(name: "Deploy", run: ["/bin/other"])
        #expect(VoiceCommandResolver.resolve(.script(deploy), text: "", catalog: VoiceCommandCatalog(scripts: [changed]))
                == .unavailable("Deploy"))
    }

    @Test func aChosenActionGetsTheFrozenInputAndNeedsTextWhenItHasNone() {
        let deploy = VoiceCommandScript(name: "Deploy", run: ["/bin/deploy", "{text}"])
        let catalog = VoiceCommandCatalog(scripts: [deploy])
        #expect(VoiceCommandResolver.resolve(.script(deploy), text: "staging", catalog: catalog)
                == .action(.script(deploy, arguments: ["staging"])))
        #expect(VoiceCommandResolver.resolve(.script(deploy), text: "", catalog: catalog) == .scriptNeedsText("Deploy"))
    }

    @Test func aChosenAppResolvesByBundleIdentity() {
        let app = App(name: "Mail", bundleId: "com.apple.mail")
        #expect(VoiceCommandResolver.resolve(.app(app), text: "", catalog: VoiceCommandCatalog()) == .action(.app(app)))
    }
}

struct VoiceCommandChoiceAnswerTests {
    private func parse(_ text: String, count: Int = 3) -> VoiceCommandChoiceAnswer {
        VoiceCommandChoiceAnswer.parse(text, count: count)
    }

    @Test(arguments: [
        "2", "two", "Two.", "2nd", "second", "number two", "number 2", "the second", "the second one", "the 2nd one",
        "second one", "to", "too", "Number to.",
    ])
    func everyAcceptedFormSelectsTheSecondRow(_ text: String) {
        #expect(parse(text) == .select(1))
    }

    @Test func homophonesMapExactly() {
        #expect(parse("won") == .select(0))
        #expect(parse("for", count: 4) == .select(3))
    }

    @Test func theLastOneMeansTheLastShownRow() {
        #expect(parse("the last one", count: 2) == .select(1))
        #expect(parse("last one", count: 5) == .select(4))
    }

    @Test func cancelAndNeverMindDismiss() {
        #expect(parse("Cancel.") == .cancel)
        #expect(parse("never mind") == .cancel)
        #expect(parse("Nevermind") == .cancel)
    }

    @Test func anOutOfRangeOrMalformedSelectionIsInvalid() {
        #expect(parse("seven") == .invalidSelection)
        #expect(parse("4", count: 3) == .invalidSelection)
        #expect(parse("zero") == .invalidSelection)
        #expect(parse("one two") == .invalidSelection)
        #expect(parse("number") == .invalidSelection)
        #expect(parse("the fourth one", count: 3) == .invalidSelection)
    }

    @Test func numbersInsideOtherSpeechAreNotGuessed() {
        #expect(parse("open two") == .unrecognized)
        #expect(parse("I want the second one please") == .unrecognized)
        #expect(parse("work mail") == .unrecognized)
        #expect(parse("") == .unrecognized)
    }
}

struct VoiceCommandSharedNameTests {
    private let personal = VoiceCommandPlace(name: "Personal Mail", say: ["mail"], target: .url("https://mail.example.net/"))
    private let work = VoiceCommandPlace(name: "Work Mail", say: ["mail"], target: .url("https://inbox.example.org/"))
    private let deploy = VoiceCommandScript(name: "Deploy", say: ["mail"], run: ["/bin/deploy"])

    @Test func aSharedNameExplainsTheQuestionItWillAsk() {
        let config = VoiceCommandConfig(places: [personal], scripts: [deploy])
        #expect(config.conflicts(for: .place(work))
                == ["\u{201C}mail\u{201D} is also a name for Personal Mail and Deploy, so saying it will ask you to choose. Give this one a name of its own."])
    }

    @Test func editingAnEntryDoesNotCollideWithItsSavedSelf() {
        let config = VoiceCommandConfig(places: [personal, work])
        var renamed = work
        renamed.say = ["inbox"]
        #expect(config.conflicts(for: .place(renamed)).isEmpty)
        #expect(config.conflicts(for: .place(work))
                == ["\u{201C}mail\u{201D} is also a name for Personal Mail, so saying it will ask you to choose. Give this one a name of its own."])
    }

    @Test func tooManySharersAreNamedAsSuch() {
        let others = (1...5).map { VoiceCommandScript(name: "Tool \($0)", say: ["build"], run: ["/bin/t\($0)"]) }
        let edited = VoiceCommandScript(name: "Builder", say: ["build"], run: ["/bin/b"])
        #expect(VoiceCommandConfig(scripts: others).conflicts(for: .script(edited))
                == ["6 commands answer to \u{201C}build\u{201D}, too many to choose from. Give this one a name of its own."])
    }

    @Test func theConflictFollowsTheMatchingRule() {
        let backUp = VoiceCommandScript(name: "Back up", run: ["/bin/a"])
        let backup = VoiceCommandScript(name: "Backup", run: ["/bin/b"])
        #expect(VoiceCommandConfig(scripts: [backUp]).conflicts(for: .script(backup)).isEmpty)
        #expect(VoiceCommandResolver.resolve("backup", catalog: VoiceCommandCatalog(scripts: [backUp, backup]))
                == .action(.script(backup, arguments: [])))

        let spaced = VoiceCommandPlace(name: "Work Mail", target: .url("https://a.example/"))
        let joined = VoiceCommandPlace(name: "Workmail", target: .url("https://b.example/"))
        #expect(VoiceCommandConfig(places: [spaced]).conflicts(for: .place(joined)).isEmpty)
        #expect(VoiceCommandResolver.resolve("workmail", catalog: VoiceCommandCatalog(places: [spaced, joined], tabs: []))
                == .action(.place(joined, .openURL("https://b.example/", browser: nil))))
        #expect(ambiguousNames(VoiceCommandResolver.resolve(
            "switch to workmail", catalog: VoiceCommandCatalog(places: [spaced, joined]))) == ["Work Mail", "Workmail"])
    }

    @Test func sharedNamesStayValidConfiguration() throws {
        let config = VoiceCommandConfig(places: [personal, work])
        #expect(config.issue == nil)
        #expect(try VoiceCommandStore.decode(from: VoiceCommandStore.encode(config)) == config)
    }
}
