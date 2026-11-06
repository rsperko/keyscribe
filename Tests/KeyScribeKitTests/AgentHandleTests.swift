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
        "Keyscribe, run the unit tests.",
        "Backend is failing after the migration.",
        "Tell me why keyscribe fails.",
        "Tell them to wait for the build.",
        "Tell the backend team the API changed.",
        "Tell everyone about the outage.",
        "Explain why \u{201C}tell keyscribe to run tests\u{201D} is ambiguous.",
    ])
    func textWithoutALeadingTellAddressIsTheMessage(text: String) {
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
        ("Tell back and to run the tests", "back and", "to run the tests"),
        ("Tell keyscribe glue to run the tests", "keyscribe glue", "to run the tests"),
        ("Tell keyscribe green to run the tests", "keyscribe green", "to run the tests"),
        ("Tell session to run the tests", "session to", "run the tests"),
        ("Tell session for, run the build", "session for", "run the build"),
    ])
    func anAddressThatMatchesNothingIsUnresolvedNeverTheMessage(text: String, spoken: String, body: String) {
        #expect(AgentAddress.parse(text, names: names) == .unresolved(spoken: spoken, body: body))
    }

    @Test(arguments: [
        ("Reply, use approach B.", "use approach B."),
        ("reply use approach B", "use approach B"),
    ])
    func replyIsItsOwnAddress(text: String, body: String) {
        #expect(AgentAddress.parse(text, names: names) == .reply(body: body))
    }

    @Test func anAddressWithNothingAfterItSelectsWithoutAMessage() {
        #expect(AgentAddress.parse("Tell keyscribe.", names: names) == .name("keyscribe", body: ""))
        #expect(AgentAddress.parse("Tell session three", names: names) == .row(3, body: ""))
        #expect(AgentAddress.parse("Reply.", names: names) == .none(body: "Reply."))
    }
}
