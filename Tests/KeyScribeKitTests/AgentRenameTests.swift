import Testing
@testable import KeyScribeKit

struct AgentRenameTests {
    @Test(arguments: [
        ("Rename this session to auth refactor.", "auth refactor"),
        ("rename this conversation to Docs", "Docs"),
        ("rename this session too build 2", "build 2"),
        ("Name this session auth refactor", "auth refactor"),
        ("Call this conversation the big one", "the big one"),
        ("Rename this session to version 1.5", "version 1.5"),
        ("Please rename this conversation to docs", "docs"),
        ("rename this conversation to docs please", "docs"),
        ("Rename this conversation to docs, please.", "docs"),
    ])
    func aWholeTakeRenamesTheCurrentConversation(text: String, name: String) {
        #expect(AgentRename.parse(text) == .rename(name))
    }

    @Test(arguments: [
        "Rename this to parseConfig",
        "rename it to parseConfig",
        "Rename this function to parse config",
        "Rename the session to sessionToken",
        "rename session to release notes",
        "Call the session handler from main",
        "Rename session two to docs",
        "Session timeout is too short",
    ])
    func anythingWithoutTheRenamePrefixIsNotARename(text: String) {
        #expect(AgentRename.parse(text) == nil)
    }

    @Test(arguments: [
        ("Rename this session to", AgentRename.Problem.noName),
        ("rename this session", .noName),
        ("Call this session.", .noName),
        ("Rename this session two to docs", .noName),
        ("Rename this session to the one we used for the parser yesterday", .tooLong),
        ("Rename this session to docs. Run the tests.", .moreAfterName),
        ("Rename this session to docs, then run the tests", .moreAfterName),
        ("Rename this session to docs\nrun the tests", .moreAfterName),
    ])
    func theRenamePrefixWithoutAUsableNameIsHeldWithTheReason(text: String, problem: AgentRename.Problem) {
        #expect(AgentRename.parse(text) == .invalid(problem))
    }

    @Test func theSpokenNameIsEverythingAfterTheCommandAsSaid() throws {
        #expect(try AgentRename.request(in: "Rename this session to docs, scratch that, notes.")?.get() == " docs, scratch that, notes.")
        #expect(try AgentRename.request(in: "Call this conversation Docs")?.get() == " Docs")
        #expect(AgentRename.request(in: "Rename this to docs") == nil)
        #expect(AgentRename.request(in: "rename this session docs") == .failure(.noName))
    }

    @Test(arguments: [
        ("notes", AgentRename.rename("notes")),
        ("  docs. ", .rename("docs")),
        ("", .invalid(.noName)),
        ("docs. Run the tests.", .invalid(.moreAfterName)),
        ("one two three four five", .invalid(.tooLong)),
    ])
    func aNameIsReadFromTheEditedNameAlone(spoken: String, expected: AgentRename) {
        #expect(AgentRename.name(from: spoken) == expected)
    }

    @Test func theNameKeepsTheWordsAsSpokenAndDropsTheEdges() {
        #expect(AgentRename.parse("Rename this session to “Auth-Refactor”!") == .rename("Auth-Refactor"))
    }

    @Test func aNameAtTheWordLimitIsARenameAndOneMoreIsTooLong() {
        let atLimit = Array(repeating: "word", count: AgentRename.nameWords).joined(separator: " ")
        #expect(AgentRename.parse("Rename this session to \(atLimit)") == .rename(atLimit))
        #expect(AgentRename.parse("Rename this session to \(atLimit) more") == .invalid(.tooLong))
    }
}
