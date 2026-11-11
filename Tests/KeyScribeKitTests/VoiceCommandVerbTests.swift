import Testing
@testable import KeyScribeKit

struct VoiceCommandVerbTests {
    private let mailId = "com.apple.mail"

    private func resolve(
        _ transcript: String, places: [VoiceCommandPlace] = [], scripts: [VoiceCommandScript] = [],
        running: [VoiceCommandCatalog.App] = [], tabs: [VoiceCommandCatalog.Tab]? = []
    ) -> VoiceCommandResolution {
        VoiceCommandResolver.resolve(transcript, catalog: VoiceCommandCatalog(
            places: places, scripts: scripts, runningApps: running, tabs: tabs, windows: .complete([])))
    }

    private let note = VoiceCommandScript(name: "New note", run: ["/bin/note", "{text}"])
    private let readingList = VoiceCommandPlace(name: "Reading list", target: .url("https://example.com/list"))
    private let issues = VoiceCommandPlace(name: "Issues", target: .tabSearch)

    @Test(arguments: [
        ("please open Mail", VoiceCommandIntent.focus(target: "mail", reach: .opening)),
        ("Open Mail, please.", .focus(target: "mail", reach: .opening)),
        ("please switch to Mail", .focus(target: "mail", reach: .running)),
        ("Repeat that, please.", .repeatSummary),
        ("please go back", .goBack),
        ("please run new note buy milk", .runScript(target: "new note buy milk")),
    ])
    func pleaseAroundARecognizedControlIsIgnored(transcript: String, intent: VoiceCommandIntent) {
        #expect(VoiceCommandGrammar.parse(transcript) == intent)
    }

    @Test(arguments: ["please", "please please", "go back to the store please", "please tell me a joke"])
    func pleaseDoesNotMakeACommand(transcript: String) {
        #expect(VoiceCommandGrammar.parse(transcript) != .goBack)
        #expect(VoiceCommandGrammar.parse(transcript) != .cancel)
    }

    @Test(arguments: ["cancel", "Cancel.", "never mind", "Nevermind!", "please cancel"])
    func cancelAloneCancels(transcript: String) {
        #expect(VoiceCommandGrammar.parse(transcript) == .cancel)
        #expect(resolve(transcript, scripts: [note]) == .cancelled)
    }

    @Test(arguments: ["cancel the deployment", "never mind the tests, run them later"])
    func cancelInsideMoreWordsIsNotCancel(transcript: String) {
        #expect(VoiceCommandGrammar.parse(transcript) != .cancel)
    }

    @Test func aSavedActionNeedsRun() {
        #expect(resolve("new note buy milk", scripts: [note]) == .needsVerb(open: nil, run: "run new note buy milk"))
        #expect(resolve("run new note buy milk", scripts: [note]) == .action(.script(note, arguments: ["buy milk"])))
        #expect(resolve("please run new note buy milk", scripts: [note]) == .action(.script(note, arguments: ["buy milk"])))
    }

    @Test func aSavedPlaceNeedsOpen() {
        #expect(resolve("reading list", places: [readingList]) == .needsVerb(open: "open reading list", run: nil))
        #expect(resolve("open reading list", places: [readingList]) != .needsVerb(open: "open reading list", run: nil))
        guard case .action(.place(readingList, _)) = resolve("open reading list", places: [readingList]) else {
            Issue.record("open did not reach the saved place")
            return
        }
    }

    @Test func aSavedTabSearchNeedsANavigationVerb() {
        #expect(resolve("issues login bug", places: [issues]) == .needsVerb(open: "open issues login bug", run: nil))
        let tab = VoiceCommandCatalog.Tab(browserBundleId: "b", window: 1, tab: 1, url: "https://x.com/1", title: "Login bug")
        #expect(resolve("switch to issues login bug", places: [issues], tabs: [tab]) == .action(.tab(tab)))
        #expect(resolve("open issues login bug", places: [issues], tabs: [tab]) == .action(.tab(tab)))
    }

    @Test func aClosingPleaseIsNotPartOfATabSearch() {
        let tab = VoiceCommandCatalog.Tab(browserBundleId: "b", window: 1, tab: 1, url: "https://x.com/1", title: "Login bug")
        let other = VoiceCommandCatalog.Tab(browserBundleId: "b", window: 1, tab: 2, url: "https://x.com/2", title: "Please read")
        #expect(resolve("open issues login bug please", places: [issues], tabs: [other, tab]) == .action(.tab(tab)))
        #expect(resolve("open reading list please", places: [readingList])
                == .action(.place(readingList, .openURL("https://example.com/list", browser: nil))))
    }

    @Test func aClosingPleaseIsDroppedWhenAChoiceIsAnswered() throws {
        let quiet = VoiceCommandScript(name: "Deploy", run: ["/bin/deploy"])
        let noisy = VoiceCommandScript(name: "Ship", say: ["deploy"], run: ["/bin/ship", "{text}"])
        let catalog = VoiceCommandCatalog(scripts: [quiet, noisy])
        guard case .ambiguous(let choice) = VoiceCommandResolver.resolve("run deploy please", catalog: catalog) else {
            Issue.record("expected a choice"); return
        }
        #expect(VoiceCommandResolver.resolve(.script(quiet), text: choice.text, reach: choice.reach, catalog: catalog)
                == .action(.script(quiet, arguments: [])))
        #expect(VoiceCommandResolver.resolve(.script(noisy), text: choice.text, reach: choice.reach, catalog: catalog)
                == .action(.script(noisy, arguments: ["please"])))
    }

    @Test func aNameAloneHintsWithoutAClosingPlease() {
        #expect(resolve("new note please", scripts: [note]) == .needsVerb(open: nil, run: "run new note please"))
        #expect(resolve("reading list please", places: [readingList]) == .needsVerb(open: "open reading list", run: nil))
    }

    @Test func aNameAPlaceAndAScriptShareOffersBothVerbs() {
        let docs = VoiceCommandPlace(name: "Docs", target: .url("https://docs.example.com/"))
        let build = VoiceCommandScript(name: "Docs", run: ["/bin/docs"])
        #expect(resolve("docs", places: [docs], scripts: [build]) == .needsVerb(open: "open docs", run: "run docs"))
    }

    @Test func aLongerSavedPlaceBeatsATabSearchItStartsWith() {
        let work = VoiceCommandPlace(name: "Work", target: .tabSearch)
        let docs = VoiceCommandPlace(name: "Work docs", target: .url("https://docs.example.com/"))
        #expect(resolve("open work docs", places: [work, docs])
                == .action(.place(docs, .openURL("https://docs.example.com/", browser: nil))))
        let tab = VoiceCommandCatalog.Tab(browserBundleId: "b", window: 1, tab: 1, url: "https://x.com/1", title: "Inbox")
        #expect(resolve("open work inbox", places: [work, docs], tabs: [tab]) == .action(.tab(tab)))
    }

    @Test func aTabSearchTiedWithAPlaceAsksWhichOne() {
        let work = VoiceCommandPlace(name: "Work", target: .tabSearch)
        let site = VoiceCommandPlace(name: "Work site", say: ["work"], target: .url("https://work.example.com/"))
        guard case .ambiguous(let choice) = resolve("open work", places: [work, site]) else {
            Issue.record("expected a choice, got \(resolve("open work", places: [work, site]))"); return
        }
        #expect(choice.candidates == [.place(work), .place(site)])
        #expect(VoiceCommandConfig(places: [work]).conflicts(for: .place(site)).isEmpty == false)
    }

    @Test func aSavedNameAfterAVerbIsCorrectableOnlyThere() {
        let read = "run new note buy milk"
        let range = VoiceCommandResolver.savedTextRange(read, places: [], scripts: [note])
        #expect(range.map { String(read[$0]) } == "buy milk")
        #expect(VoiceCommandResolver.savedTextRange("new note buy milk", places: [], scripts: [note]) == nil)
    }
}
