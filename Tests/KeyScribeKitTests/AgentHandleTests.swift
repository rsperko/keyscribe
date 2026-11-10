import Foundation
import Testing
@testable import KeyScribeKit

struct AgentHandleTests {
    @Test(arguments: [
        ("keyscribe", "keyscribe"),
        ("KeyScribe", "keyscribe"),
        ("my-api_server", "my api server"),
        ("v2.app", "v2 app"),
        ("  spaced  out ", "spaced out"),
    ])
    func folderNamesBecomeSpeakableBases(folder: String, base: String) {
        #expect(AgentHandles.base(forFolder: folder) == base)
    }

    @Test(arguments: [
        ("Keyscribe 2", "keyscribe two"),
        ("keyscribe-two", "keyscribe two"),
        ("KEYSCRIBE  two.", "keyscribe two"),
        ("backend 10", "backend ten"),
        ("backend 11", "backend 11"),
    ])
    func spokenAndWrittenFormsNormalizeAlike(raw: String, normalized: String) {
        #expect(AgentHandles.normalize(raw) == normalized)
    }

    @Test func firstConversationInAProjectTakesTheBareFolderName() {
        let assigned = AgentHandles.assign([.init(id: "a", folder: "keyscribe")], existing: [:])
        #expect(assigned == ["a": "keyscribe"])
    }

    @Test func laterConversationsInTheSameProjectGetADistinguishingWord() {
        let assigned = AgentHandles.assign(
            [.init(id: "a", folder: "keyscribe"), .init(id: "b", folder: "keyscribe"), .init(id: "c", folder: "keyscribe")],
            existing: [:])
        #expect(assigned == ["a": "keyscribe", "b": "keyscribe blue", "c": "keyscribe green"])
    }

    @Test func generatedNamesNeverContainANumber() {
        let convs = (1...40).map { AgentHandles.Conversation(id: "c\($0)", folder: "proj") }
        let names = AgentHandles.assign(convs, existing: [:]).values
        #expect(Set(names).count == 40)
        #expect(names.allSatisfy { !$0.contains(where: \.isNumber) })
        #expect(names.allSatisfy { name in !name.split(separator: " ").contains { ["two", "to", "too", "four", "for"].contains($0) } })
    }

    @Test func aWordAlreadyInTheProjectNameIsSkipped() {
        let assigned = AgentHandles.assign([.init(id: "a", folder: "blue"), .init(id: "b", folder: "blue")], existing: [:])
        #expect(assigned["b"] == "blue green")
    }

    @Test func anExistingHandleNeverChanges() {
        let assigned = AgentHandles.assign(
            [.init(id: "new", folder: "keyscribe"), .init(id: "old", folder: "keyscribe")],
            existing: ["old": "keyscribe"])
        #expect(assigned["old"] == "keyscribe")
        #expect(assigned["new"] == "keyscribe blue")
    }

    @Test func aRenamedHandleKeepsItsNameAndFreesNothingItDidNotOwn() {
        let assigned = AgentHandles.assign(
            [.init(id: "a", folder: "keyscribe"), .init(id: "b", folder: "keyscribe")],
            existing: ["a": "backend"])
        #expect(assigned == ["a": "backend", "b": "keyscribe"])
    }

    @Test func renameRejectsAHandleAnotherConversationHolds() throws {
        let current = ["a": "backend", "b": "frontend"]
        #expect(throws: AgentHandles.RenameError.taken) { try AgentHandles.rename("b", to: "Backend", in: current) }
        #expect(throws: AgentHandles.RenameError.empty) { try AgentHandles.rename("b", to: "  ", in: current) }
        #expect(try AgentHandles.rename("b", to: "Web UI", in: current) == ["a": "backend", "b": "web ui"])
    }

    @Test func aGeneratedNameNeverMatchesAnExistingOneOnceSpacesAreIgnored() {
        let assigned = AgentHandles.assign([.init(id: "a", folder: "x"), .init(id: "b", folder: "backend")], existing: ["a": "back end"])
        #expect(assigned["b"] == "backend blue")
    }

    @Test(arguments: ["session", "Session 2", "session two", "session to", "session for"])
    func renameRejectsNamesTheAddressGrammarOwns(name: String) {
        #expect(throws: AgentHandles.RenameError.reserved) { try AgentHandles.rename("a", to: name, in: ["a": "x"]) }
    }

    @Test func aProjectNamedLikeTheAddressGrammarGetsADistinguishingWord() {
        #expect(AgentHandles.assign([.init(id: "a", folder: "session")], existing: [:])["a"] == "session blue")
        #expect(AgentHandles.assign([.init(id: "a", folder: "session-manager")], existing: [:])["a"] == "session manager")
    }

    @Test func renameRejectsANameThatMatchesAnotherOnceSpacesAreIgnored() {
        #expect(throws: AgentHandles.RenameError.taken) { try AgentHandles.rename("b", to: "Back End", in: ["a": "backend", "b": "x"]) }
    }

    @Test func namesMatchWhetherOrNotSpeechRecognitionJoinedTheWords() {
        #expect(AgentHandles.matchKey("Backend Purple") == AgentHandles.matchKey("BackendPurple"))
        #expect(AgentHandles.matchKey("backend-purple") == "backendpurple")
    }
}

struct AgentAddressTests {
    let names = ["keyscribe", "keyscribe blue", "backend", "my api", "session manager"]

    @Test(arguments: [
        ("Tell keyscribe run the unit tests", "keyscribe", "run the unit tests"),
        ("Tell keyscribe, run the unit tests.", "keyscribe", "run the unit tests."),
        ("tell Keyscribe: run the unit tests", "keyscribe", "run the unit tests"),
        ("Tell keyscribe blue to run the unit tests.", "keyscribe blue", "to run the unit tests."),
        ("Tell keyscribe two tests are failing.", "keyscribe", "two tests are failing."),
        ("Tell keyscribe not to run the tests.", "keyscribe", "not to run the tests."),
        ("Please tell backend to add a retry.", "backend", "to add a retry."),
        ("Tell KeyscribeBlue to run the unit tests.", "keyscribe blue", "to run the unit tests."),
        ("Tell backend to run, then report", "backend", "to run, then report"),
        ("Tell backend run the tests: unit first", "backend", "run the tests: unit first"),
        ("Tell my api to run the tests.", "my api", "to run the tests."),
        ("Tell session manager to restart.", "session manager", "to restart."),
    ])
    func aLeadingTellAddressesTheLongestMatchingName(text: String, name: String, body: String) {
        #expect(AgentAddress.parse(text, names: names) == .name(name, body: body))
    }

    @Test func theMessageAfterTheAddressIsKeptExactlyAsSaid() {
        let text = "Tell backend,\nnpm test  --watch\nthen report"
        #expect(AgentAddress.parse(text, names: names) == .name("backend", body: "npm test  --watch\nthen report"))
    }

    @Test(arguments: [
        ("Tell session four to run the build.", 4, "to run the build."),
        ("tell session 4 run the build", 4, "run the build"),
        ("Tell session two, check the migration.", 2, "check the migration."),
        ("Please tell session twelve to stop.", 12, "to stop."),
    ])
    func aLeadingTellSessionAddressesAVisibleRow(text: String, row: Int, body: String) {
        #expect(AgentAddress.parse(text, names: names) == .row(row, body: body))
    }

    @Test(arguments: [
        ("keyscribe what is going on with this right now?", "keyscribe", "what is going on with this right now?"),
        ("Keyscribe, run the unit tests.", "keyscribe", "run the unit tests."),
        ("Keyscribe blue: run the unit tests.", "keyscribe blue", "run the unit tests."),
        ("Backend is failing after the migration.", "backend", "is failing after the migration."),
        ("My api, add a retry.", "my api", "add a retry."),
    ])
    func aLeadingNameAddressesWithoutTell(text: String, name: String, body: String) {
        #expect(AgentAddress.parse(text, names: names) == .name(name, body: body))
    }

    @Test(arguments: [
        ("Tell jk boots to run the tests.", "foo jk boots manager 1234", "to run the tests."),
        ("tell boots jk, run the tests", "foo jk boots manager 1234", "run the tests"),
        ("jk boots run the tests", "foo jk boots manager 1234", "run the tests"),
        ("Tell jk boots manager fix it", "foo jk boots manager 1234", "fix it"),
        ("tell boots, manager is down", "foo jk boots manager 1234", "manager is down"),
        ("Tell keyscribe, run the tests", "keyscribe", "run the tests"),
    ])
    func partOfANameInAnyOrderAddressesIt(text: String, name: String, body: String) {
        #expect(AgentAddress.parse(text, names: names + ["foo jk boots manager 1234"]) == .name(name, body: body))
    }

    @Test func aNameWordRepeatedInTheMessageStaysInTheMessage() {
        let names = ["release manager", "build"]
        #expect(AgentAddress.parse("Tell release manager release the package", names: names) == .name("release manager", body: "release the package"))
        #expect(AgentAddress.parse("Tell build build the project", names: names) == .name("build", body: "build the project"))
    }

    @Test func aCommaEndsTheAddressForNearMatchesToo() {
        #expect(AgentAddress.parse("Tell keyscribe, blue is the failing theme", names: names) == .name("keyscribe", body: "blue is the failing theme"))
        #expect(AgentAddress.parse("keyscribe, blue is the failing theme", names: names) == .name("keyscribe", body: "blue is the failing theme"))
    }

    @Test func aMisheardAddressWithoutTellIsHeldNotSentToTheCurrentConversation() {
        #expect(AgentAddress.parse("Session to run the build", names: names) == .unresolved(spoken: "session to", body: "run the build"))
        #expect(AgentAddress.parse("Keyscrib run the tests", names: names)
            == .nearMiss(spoken: "keyscrib", name: "keyscribe", body: "run the tests", unaddressed: "Keyscrib run the tests"))
    }

    @Test(arguments: [
        ("Tell back and to run the tests", "back and", "backend", "to run the tests"),
    ])
    func anAddressThatSoundsLikeANameNamesIt(text: String, spoken: String, name: String, body: String) {
        #expect(AgentAddress.parse(text, names: names) == .nearMiss(spoken: spoken, name: name, body: body, unaddressed: nil))
    }

    @Test(arguments: [
        ("Review these changes", "review", "preview", "these changes"),
        ("Update the dependencies", "update", "updates", "the dependencies"),
    ])
    func anInstructionWhoseFirstWordSoundsLikeANameIsANearMissThatCanStillBeTheMessage(
        text: String, spoken: String, name: String, body: String
    ) {
        #expect(AgentAddress.parse(text, names: ["preview", "updates"]) == .nearMiss(spoken: spoken, name: name, body: body, unaddressed: text))
    }

    @Test func aShortWordCloseToANameIsStillTheMessageWithoutTell() {
        #expect(AgentAddress.parse("Build the project", names: ["builds"]) == .none(body: "Build the project"))
        #expect(AgentAddress.parse("Test the login flow", names: ["tests"]) == .none(body: "Test the login flow"))
        #expect(AgentAddress.parse("Tell build the project", names: ["builds"]) == .name("builds", body: "the project"))
    }

    @Test func theLongestMatchingPartOfANameWins() {
        let names = ["jk boots", "foo jk boots manager 1234"]
        #expect(AgentAddress.parse("tell jk boots fix it", names: names) == .name("jk boots", body: "fix it"))
        #expect(AgentAddress.parse("tell jk boots manager fix it", names: names) == .name("foo jk boots manager 1234", body: "fix it"))
    }

    @Test func partOfSeveralNamesIsAmbiguous() {
        let names = ["jk boots manager", "mk boots", "frontend"]
        #expect(AgentAddress.parse("tell boots, fix it", names: names) == .ambiguous(spoken: "boots", names: ["jk boots manager", "mk boots"], body: "fix it"))
    }

    @Test func withoutTellOneWordOfALongerNameIsTheMessage() {
        let names = ["foo jk boots manager 1234"]
        #expect(AgentAddress.parse("Boots are on sale.", names: names) == .none(body: "Boots are on sale."))
        #expect(AgentAddress.parse("tell boots they are on sale", names: names) == .name("foo jk boots manager 1234", body: "they are on sale"))
    }

    @Test func aSessionNumberIsTheRowEvenWhenTheWordsAfterItAreAName() {
        let names = names + ["one foobar"]
        #expect(AgentAddress.parse("tell session one foobar is broke", names: names) == .row(1, body: "foobar is broke"))
        #expect(AgentAddress.parse("session one foobar is broke", names: names) == .row(1, body: "foobar is broke"))
        #expect(AgentAddress.parse("tell one foobar it is broke", names: names) == .name("one foobar", body: "it is broke"))
    }

    @Test func aLeadingSessionNumberAddressesWithoutTell() {
        #expect(AgentAddress.parse("Session two, check the migration.", names: names) == .row(2, body: "check the migration."))
        #expect(AgentAddress.parse("session 4 run the build", names: names) == .row(4, body: "run the build"))
    }

    @Test func anAcceptedNameKeepsItsBoundaryWhenTheNextWordSoundsLikeALongerName() {
        #expect(AgentAddress.parse("Tell keyscribe glue the adapters together", names: names) == .name("keyscribe", body: "glue the adapters together"))
        #expect(AgentAddress.parse("Keyscribe glue to run the tests", names: names) == .name("keyscribe", body: "glue to run the tests"))
    }

    @Test(arguments: [
        "Frontend, run the tests.",
        "Run the tests in keyscribe.",
        "Tell me why keyscribe fails.",
        "Tell them to wait for the build.",
        "Tell everyone about the outage.",
        "Explain why \u{201C}tell keyscribe to run tests\u{201D} is ambiguous.",
    ])
    func textWithoutALeadingAddressIsTheMessage(text: String) {
        #expect(AgentAddress.parse(text, names: names) == .none(body: text))
    }

    @Test(arguments: [
        ("Tell frontend, run the tests.", "frontend", "run the tests."),
        ("Tell frontend to run the tests.", "frontend", "to run the tests."),
        ("Tell frontend run the tests", "frontend", "run the tests"),
        ("Tell frontend why the tests failed", "frontend", "why the tests failed"),
        ("Tell frontend about the outage", "frontend", "about the outage"),
        ("Tell users that the API changed.", "users", "that the API changed."),
        ("Tell frontend to run, then report", "frontend", "to run, then report"),
        ("Tell Claude to check the logs", "claude", "to check the logs"),
        ("Tell back end blue: run the tests.", "back end blue", "run the tests."),
        ("Tell keyscribe green to run the tests", "keyscribe green", "to run the tests"),
        ("Tell session to run the tests", "session to", "run the tests"),
        ("Tell session for, run the build", "session for", "run the build"),
    ])
    func anAddressThatMatchesNothingIsUnresolvedNeverTheMessage(text: String, spoken: String, body: String) {
        #expect(AgentAddress.parse(text, names: names) == .unresolved(spoken: spoken, body: body))
    }

    @Test func anAddressWithNothingAfterItSelectsWithoutAMessage() {
        #expect(AgentAddress.parse("Tell keyscribe.", names: names) == .name("keyscribe", body: ""))
        #expect(AgentAddress.parse("Tell session three", names: names) == .row(3, body: ""))
    }

    @Test(arguments: [
        ("tell my api run the tests", "my"),
        ("Tell the api to run the tests.", "the"),
        ("please tell keyscribe blue to run the tests", "keyscribe"),
        ("tell me what failed", "me"),
    ])
    func withoutKnownNamesEveryTellThatIsNotARowIsUnresolved(text: String, spoken: String) {
        guard case .unresolved(let said, _) = AgentAddress.parse(text, names: [], namesKnown: false) else {
            Issue.record("\(text) was not held back")
            return
        }
        #expect(said.hasPrefix(spoken))
    }

    @Test func withoutKnownNamesRowsAndUnaddressedTextStillWork() {
        #expect(AgentAddress.parse("tell session 2 run the tests", names: [], namesKnown: false) == .row(2, body: "run the tests"))
        #expect(AgentAddress.parse("run the tests", names: [], namesKnown: false) == .none(body: "run the tests"))
        #expect(AgentAddress.parse("my api run the tests", names: [], namesKnown: false) == .none(body: "my api run the tests"))
        #expect(AgentAddress.parse("session 2 run the tests", names: [], namesKnown: false) == .row(2, body: "run the tests"))
    }

    @Test(arguments: [
        ("Open keyscribe.", AgentAddress.name("keyscribe", body: "")),
        ("switch to backend", .name("backend", body: "")),
        ("Which to keyscribe blue", .name("keyscribe blue", body: "")),
        ("Go to session two.", .row(2, body: "")),
        ("focus on my api", .name("my api", body: "")),
        ("Focus backend", .name("backend", body: "")),
        ("Launch the backend.", .name("backend", body: "")),
        ("Open, keyscribe", .name("keyscribe", body: "")),
    ])
    func aBringForwardVerbBeforeAnAddressOpensIt(text: String, inner: AgentAddress) {
        #expect(AgentAddress.parse(text, names: names) == .open(inner))
    }

    @Test(arguments: [
        "Open keyscribe and run the tests.",
        "Go to the definition of backend and read it.",
        "Focus on the failing tests in the parser.",
        "Open the settings page and fix the toggle",
        "Open it.",
        "Open",
    ])
    func aBringForwardVerbFollowedByMoreThanAFewWordsOrAPronounIsTheMessage(text: String) {
        #expect(AgentAddress.parse(text, names: names) == .none(body: text))
    }

    @Test(arguments: [
        ("Open the readme.", "readme"),
        ("Switch to the main branch.", "main branch"),
        ("Go to the definition of backend.", "definition of backend"),
        ("Focus on the failing tests.", "failing tests"),
        ("Go to key scrub", "key scrub"),
        ("Open session zebra", "zebra"),
        ("Open session the big long name here", "the big long name here"),
        ("Go to session backend review", "backend review"),
        ("Open session two run the build", "two run the build"),
    ])
    func aBringForwardVerbWithAFewWordsThatNameNothingIsHeld(text: String, spoken: String) {
        #expect(AgentAddress.parse(text, names: names) == .open(.unresolved(spoken: spoken, body: "")))
        #expect(AgentAddress.parse(text, names: ["backend"]) == .open(.unresolved(spoken: spoken, body: "")))
    }

    @Test func theClosestNamesToAHeldTargetAreSuggestedAndTiesStayTogether() {
        #expect(AgentAddress.closest(to: "key scrub", among: names) == ["keyscribe"])
        #expect(AgentAddress.closest(to: "key scrub", among: ["keyscribe", "keyscrabe", "backend"]) == ["keyscrabe", "keyscribe"])
        #expect(AgentAddress.closest(to: "readme", among: names) == [])
        #expect(AgentAddress.closest(to: "keyscribe", among: ["backend", "frontend"]) == [])
    }

    @Test func openingNeedsTheSameEvidenceAsAnAddressWithoutTell() {
        let names = ["jk boots manager", "jk boots helper", "frontend"]
        #expect(AgentAddress.parse("open boots", names: names) == .open(.unresolved(spoken: "boots", body: "")))
        #expect(AgentAddress.parse("open jk boots", names: names)
            == .open(.ambiguous(spoken: "jk boots", names: ["jk boots helper", "jk boots manager"], body: "")))
        #expect(AgentAddress.parse("switch to boots manager", names: names) == .open(.name("jk boots manager", body: "")))
    }

    @Test func anOpenThatSoundsLikeAnAddressButMissesIsHeld() {
        #expect(AgentAddress.parse("Open session to", names: names) == .open(.unresolved(spoken: "session to", body: "")))
        #expect(AgentAddress.parse("open keyscrib", names: names)
            == .open(.nearMiss(spoken: "keyscrib", name: "keyscribe", body: "", unaddressed: "keyscrib")))
    }

    @Test(arguments: [
        ("session backend run unit tests", AgentAddress.name("backend", body: "run unit tests")),
        ("Tell session backend, run unit tests.", .name("backend", body: "run unit tests.")),
        ("Session keyscribe blue to run the tests", .name("keyscribe blue", body: "to run the tests")),
        ("Open session backend", .open(.name("backend", body: ""))),
        ("Session manager, check the logs.", .name("session manager", body: "check the logs.")),
        ("tell session frobnicate, run it", .unresolved(spoken: "frobnicate", body: "run it")),
        ("Tell session, run the build.", .name("session manager", body: "run the build.")),
    ])
    func sessionMayComeBeforeAName(text: String, expected: AgentAddress) {
        #expect(AgentAddress.parse(text, names: names) == expected)
    }

    @Test(arguments: ["Session timeout is too short.", "Session cookies are not cleared on logout."])
    func aSentenceAboutSessionsIsTheMessage(text: String) {
        #expect(AgentAddress.parse(text, names: names) == .none(body: text))
    }

    private let numbered = ["backend", "frontend", "two bugs", "two", "one", "for"]

    @Test(arguments: [
        "One more thing: check the migration.",
        "For the record, the build is green.",
        "Two tests failed.",
        "Two, run tests.",
        "4 files changed.",
    ])
    func aSentenceThatStartsWithANumberIsTheMessageEvenWhenANameIsThatNumber(text: String) {
        #expect(AgentAddress.parse(text, names: numbered) == .none(body: text))
    }

    @Test func theLongestNameWinsOverANumberNameItStartsWith() {
        #expect(AgentAddress.parse("Two bugs, run tests.", names: numbered) == .name("two bugs", body: "run tests."))
        #expect(AgentAddress.parse("Two bugs are left in the parser", names: numbered) == .name("two bugs", body: "are left in the parser"))
    }

    @Test func aNumberNameIsReachedByTellOrOpen() {
        #expect(AgentAddress.parse("Tell two, run tests.", names: numbered) == .name("two", body: "run tests."))
        #expect(AgentAddress.parse("tell for, run it", names: numbered) == .name("for", body: "run it"))
        #expect(AgentAddress.parse("Open two.", names: numbered) == .open(.name("two", body: "")))
        #expect(AgentAddress.parse("open for", names: numbered) == .open(.name("for", body: "")))
    }

    @Test func sessionAndANumberIsAlwaysTheRowEvenWhenANameIsThatNumber() {
        #expect(AgentAddress.parse("Session two, run tests.", names: numbered) == .row(2, body: "run tests."))
        #expect(AgentAddress.parse("Open session two.", names: numbered) == .open(.row(2, body: "")))
    }

    @Test func aMissingNumberNameIsHeldAfterTellOrOpenAndNeverBecomesARow() {
        let names = ["backend", "frontend"]
        #expect(AgentAddress.parse("Tell two, run tests.", names: names) == .unresolved(spoken: "two", body: "run tests."))
        #expect(AgentAddress.parse("Open two.", names: names) == .open(.unresolved(spoken: "two", body: "")))
        #expect(AgentAddress.parse("open for", names: names) == .open(.unresolved(spoken: "for", body: "")))
        #expect(AgentAddress.parse("Two, run tests.", names: names) == .none(body: "Two, run tests."))
    }

    @Test func openingFilesIsAMessageOnlyWhenMoreThanAFewWordsFollowTheVerb() {
        let long = "Open 2 files and compare them."
        #expect(AgentAddress.parse(long, names: numbered) == .none(body: long))
        #expect(AgentAddress.parse(long, names: ["backend"]) == .none(body: long))
        #expect(AgentAddress.parse("Open two files.", names: numbered) == .none(body: "Open two files."))
        #expect(AgentAddress.parse("Open two files.", names: ["backend"]) == .open(.unresolved(spoken: "two files", body: "")))
    }

    private static func reading(_ text: String) -> String {
        text.replacingOccurrences(of: "R Sperco", with: "rsperko", options: .caseInsensitive)
            .replacingOccurrences(of: "Arsperco", with: "rsperko", options: .caseInsensitive)
    }
    private let readable = ["rsperko", "rsperko blue", "rsperko green", "home green"]

    @Test(arguments: [
        ("Go to Arsperco Green.", AgentAddress.open(.name("rsperko green", body: ""))),
        ("Go to R Sperco Green", .open(.name("rsperko green", body: ""))),
        ("Switch to arsperco", .open(.name("rsperko", body: ""))),
        ("Tell R Sperco Green to run the tests.", .name("rsperko green", body: "to run the tests.")),
        ("Arsperco blue, run the tests.", .name("rsperko blue", body: "run the tests.")),
    ])
    func wordsTheReadingCorrectsIntoANameAddressIt(text: String, expected: AgentAddress) {
        #expect(AgentAddress.parse(text, names: readable, read: Self.reading) == expected)
    }

    @Test func theBodyAfterACorrectedAddressIsKeptExactlyAsSaid() {
        #expect(AgentAddress.parse("Tell Arsperco Green, ask R Sperco about it", names: readable, read: Self.reading)
            == .name("rsperko green", body: "ask R Sperco about it"))
    }

    @Test func aRawMatchWinsOverTheReading() {
        let read: (String) -> String = { $0.replacingOccurrences(of: "home", with: "rsperko") }
        #expect(AgentAddress.parse("Tell home green to stop", names: readable, read: read) == .name("home green", body: "to stop"))
    }

    @Test func aReadingThatNamesNothingLeavesTheAddressAsHeard() {
        let names = ["home green"]
        #expect(AgentAddress.parse("Go to Arsperco Purple.", names: names, read: Self.reading)
            == AgentAddress.parse("Go to Arsperco Purple.", names: names))
    }

    @Test func anAddressHeardAsANearMissOfANameIsTheNameOnceTheReadingCorrectsIt() {
        let names = ["rsperko green"]
        guard case .open(.nearMiss) = AgentAddress.parse("Go to Arsperco Green.", names: names) else {
            Issue.record("the uncorrected address should be a near miss")
            return
        }
        #expect(AgentAddress.parse("Go to Arsperco Green.", names: names, read: Self.reading)
            == .open(.name("rsperko green", body: "")))
    }

    @Test func aReadingMayJoinMoreWordsThanTheNameHas() {
        let read: (String) -> String = { $0.replacingOccurrences(of: "R Sper Co", with: "rsperko") }
        #expect(AgentAddress.parse("Tell R Sper Co Green to stop", names: readable, read: read)
            == .name("rsperko green", body: "to stop"))
    }

    @Test(arguments: ["backend", "backand"])
    func aCorrectionNeverChoosesBetweenNamesTheWordsSoundEquallyLike(corrected: String) {
        let names = ["backend", "backand"]
        let read: (String) -> String = { $0.replacingOccurrences(of: "backund", with: corrected) }
        #expect(AgentAddress.parse("Tell backund to stop", names: names, read: read)
            == AgentAddress.parse("Tell backund to stop", names: names))
    }

    @Test func aCorrectedNameFollowedByAnotherDistinguishingWordStillAsks() {
        #expect(AgentAddress.parse("Go to Arsperco Purple.", names: readable, read: Self.reading)
            == .open(.unresolved(spoken: "arsperco purple", body: "")))
    }

    @Test(arguments: [
        ("Ask backend to review the changes.", AgentAddress.name("backend", body: "to review the changes.")),
        ("ask backend whether the migration is needed", .name("backend", body: "whether the migration is needed")),
        ("Please ask keyscribe blue to run the tests", .name("keyscribe blue", body: "to run the tests")),
        ("Ask session two to rerun the tests.", .row(2, body: "to rerun the tests.")),
        ("Ask backend: what changed?", .name("backend", body: "what changed?")),
        ("ask backund to review", .nearMiss(spoken: "backund", name: "backend", body: "to review", unaddressed: nil)),
        ("Ask backend.", .name("backend", body: "")),
        ("So tell backend to continue.", .name("backend", body: "to continue.")),
        ("Okay, ask backend to review it", .name("backend", body: "to review it")),
        ("Hey please tell session two to stop", .row(2, body: "to stop")),
    ])
    func askAddressesALiveNameOrRow(text: String, address: AgentAddress) {
        #expect(AgentAddress.parse(text, names: names) == address)
    }

    @Test(arguments: [
        ("Hey backend, run the tests.", AgentAddress.name("backend", body: "run the tests.")),
        ("okay backend run the tests", .name("backend", body: "run the tests")),
        ("So session two, check the build", .row(2, body: "check the build")),
        ("Okay, open backend.", .open(.name("backend", body: ""))),
    ])
    func anOpenerBeforeABareAddressIsSkipped(text: String, address: AgentAddress) {
        #expect(AgentAddress.parse(text, names: names) == address)
    }

    @Test func aNameThatStartsWithAnOpenerIsMatchedWholeFirst() {
        let names = ["so long", "long", "backend"]
        #expect(AgentAddress.parse("so long, run the tests", names: names) == .name("so long", body: "run the tests"))
        #expect(AgentAddress.parse("So backend is failing", names: names) == .name("backend", body: "is failing"))
        #expect(AgentAddress.parse("Okay long, run the tests", names: names) == .name("long", body: "run the tests"))
    }

    @Test(arguments: ["So the tests are failing.", "Okay, run the tests.", "Hey, what changed?", "okay"])
    func anOpenerBeforeAnythingElseLeavesTheMessageWhole(text: String) {
        #expect(AgentAddress.parse(text, names: names) == .none(body: text))
    }

    @Test(arguments: [
        "Ask clarifying questions before you start.",
        "ask questions if anything is unclear",
        "Ask users for feedback on the design.",
        "ask again if it fails",
        "Ask yourself whether the cache is needed.",
        "ask me before you push",
        "So the tests are failing.",
        "Okay, tell me why it failed.",
        "Ask for confirmation before deleting anything.",
        "Ask the user whether to keep the schema.",
        "Ask",
    ])
    func askBeforeAnythingButALiveNameIsTheMessage(text: String) {
        #expect(AgentAddress.parse(text, names: names) == .none(body: text))
    }

    @Test(arguments: [
        ("Tell the backend to review the changes.", AgentAddress.name("backend", body: "to review the changes.")),
        ("ask the backend what it is doing", .name("backend", body: "what it is doing")),
        ("Ask the backend, what changed?", .name("backend", body: "what changed?")),
        ("Tell the backend.", .name("backend", body: "")),
        ("tell the session manager that the build is green", .name("session manager", body: "that the build is green")),
        ("Ask the backund whether it is done", .nearMiss(spoken: "backund", name: "backend", body: "whether it is done", unaddressed: nil)),
        ("Please ask the session two to stop", .row(2, body: "to stop")),
    ])
    func theAfterTellOrAskIsSkippedWhenANameFollowsWithABreak(text: String, address: AgentAddress) {
        #expect(AgentAddress.parse(text, names: names) == address)
    }

    @Test(arguments: [
        ("Tell the backend team the API changed.", AgentAddress.name("backend", body: "team the API changed.")),
        ("Ask the backend team for the logs.", .name("backend", body: "team for the logs.")),
        ("tell the backend run the tests", .name("backend", body: "run the tests")),
        ("Tell the session two run the tests", .row(2, body: "run the tests")),
        ("tell the backund run the tests", .nearMiss(spoken: "backund", name: "backend", body: "run the tests", unaddressed: nil)),
    ])
    func theBeforeAnAddressWithoutABreakIsHeldNeverSentElsewhere(text: String, inner: AgentAddress) {
        #expect(AgentAddress.parse(text, names: names) == .unbroken(inner, unaddressed: text))
    }

    @Test(arguments: ["Tell the users that the API changed.", "ask the team whether it is done"])
    func theBeforeWordsThatNameNoConversationIsTheMessage(text: String) {
        #expect(AgentAddress.parse(text, names: names) == .none(body: text))
    }

    @Test func aNameThatStartsWithTheIsMatchedWhole() {
        let names = ["big one", "the big one", "architect"]
        #expect(AgentAddress.parse("Tell the big one to stop", names: names) == .name("the big one", body: "to stop"))
        #expect(AgentAddress.parse("ask the big one what it needs", names: names) == .name("the big one", body: "what it needs"))
        #expect(AgentAddress.parse("Tell the architect to stop", names: names) == .name("architect", body: "to stop"))
    }
}

struct AgentShorterNameTests {
    private func reaches(_ spoken: String, _ name: String, among names: [String]) -> Bool {
        if case .name(name, let body) = AgentAddress.parse("\(spoken), run the unit tests.", names: names) { return !body.isEmpty }
        return false
    }

    @Test func aLongNameOffersTheShortestLeadingWordsTheMatcherAcceptsForIt() throws {
        let names = ["fix authentication retries", "backend"]
        let short = try #require(AgentAddress.shorterSpokenName(for: "fix authentication retries", among: names))
        #expect("fix authentication retries".hasPrefix(short + " "))
        #expect(reaches(short, "fix authentication retries", among: names))
        let words = short.split(separator: " ")
        for count in 1..<words.count {
            #expect(!reaches(words.prefix(count).joined(separator: " "), "fix authentication retries", among: names))
        }
    }

    @Test func leadingWordsSharedWithAnotherConversationAreNeverOffered() {
        let names = ["fix authentication retries", "fix authentication tests"]
        let short = AgentAddress.shorterSpokenName(for: "fix authentication retries", among: names)
        #expect(short == nil)
    }

    @Test func aShorterNameNeverEndsOnAConnectingWord() {
        let names = ["deploy the staging cluster", "chief of staff project tracking"]
        #expect(AgentAddress.shorterSpokenName(for: "deploy the staging cluster", among: names) == "deploy the staging")
        #expect(AgentAddress.shorterSpokenName(for: "chief of staff project tracking", among: names) == "chief of staff")
    }

    @Test func aOneWordNameHasNothingShorter() {
        #expect(AgentAddress.shorterSpokenName(for: "backend", among: ["backend"]) == nil)
    }
}
