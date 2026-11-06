import Foundation
import Testing
@testable import KeyScribeKit

struct AgentDirectoryTests {
    private func claude(_ pid: Int, _ session: String, cwd: String = "/src/keyscribe", status: String = "idle", waitingFor: String? = nil) -> ClaudeRegistryEntry {
        ClaudeRegistryEntry(pid: pid, sessionId: session, cwd: cwd, name: nil, status: status, waitingFor: waitingFor)
    }

    @Test func registrySessionsBecomeConversationsWithHandles() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a"), claude(11, "b"), claude(12, "c", cwd: "/src/chatplay")], live: ["a", "b"])
        let byId = Dictionary(uniqueKeysWithValues: directory.conversations.map { ($0.id, $0) })
        #expect(byId["a"]?.handle == "keyscribe")
        #expect(byId["b"]?.handle == "keyscribe blue")
        #expect(byId["c"]?.handle == "chatplay")
        #expect(byId["a"]?.connectorLive == true)
        #expect(byId["c"]?.connectorLive == false)
        #expect(byId["c"]?.state == .idle)
    }

    @Test func aNameStaysWithItsConversationWhenTheTerminalSwitchesToAnother() throws {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        try directory.rename("a", to: "backend")
        directory.update(claude: [claude(10, "a2")], live: [])
        #expect(directory.conversation(handle: "backend") == nil)
        #expect(directory.conversation(pid: 10)?.handle == "keyscribe")
        directory.update(claude: [claude(10, "a")], live: [])
        #expect(directory.conversation(handle: "backend")?.id == "a")
    }

    @Test func aChosenNameStaysReservedForItsConversationWhileItIsAway() throws {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        try directory.rename("a", to: "backend")
        directory.update(claude: [claude(20, "b", cwd: "/src/backend")], live: [])
        #expect(directory.conversation(pid: 20)?.handle == "backend blue")
        directory.update(claude: [claude(20, "b", cwd: "/src/backend"), claude(10, "a")], live: [])
        #expect(directory.conversation(handle: "backend")?.id == "a")
    }

    @Test func nobodyElseCanTakeAChosenNameWhileItsConversationIsAway() throws {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        try directory.rename("a", to: "backend")
        directory.update(claude: [claude(20, "b")], live: [])
        #expect(throws: AgentHandles.RenameError.taken) { try directory.rename("b", to: "Back End") }
    }

    @Test func aReturningConversationNeverTakesBackANameSomeoneElseChose() throws {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a", cwd: "/src/api")], live: [])
        directory.update(claude: [], live: [])
        directory.update(claude: [claude(20, "b", cwd: "/src/api")], live: [])
        try directory.rename("b", to: "api")
        directory.update(claude: [], live: [])
        directory.update(claude: [claude(10, "a", cwd: "/src/api")], live: [])
        #expect(directory.conversation(pid: 10)?.handle == "api blue")
        directory.update(claude: [claude(10, "a", cwd: "/src/api"), claude(20, "b", cwd: "/src/api")], live: [])
        #expect(directory.conversation(handle: "api")?.id == "b")
    }

    @Test func aGeneratedNameIsReusedWhileItsConversationIsAway() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        directory.update(claude: [claude(10, "a2")], live: [])
        #expect(directory.conversation(handle: "keyscribe")?.id == "a2")
    }

    @Test func aHandleSurvivesTheProcessRestartingWithTheSameSession() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        directory.update(claude: [], live: [])
        directory.update(claude: [claude(20, "a")], live: [])
        #expect(directory.conversation(handle: "keyscribe")?.pid == 20)
    }

    @Test func renamingAHandleSticksAcrossUpdates() throws {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        try directory.rename("a", to: "Backend")
        directory.update(claude: [claude(10, "a", status: "busy")], live: [])
        #expect(directory.conversation(handle: "backend")?.state == .working)
        #expect(directory.conversation(handle: "keyscribe") == nil)
    }

    @Test func handlesAreLookedUpBySpokenForm() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a"), claude(11, "b")], live: [])
        #expect(directory.conversation(handle: "KeyscribeBlue")?.id == "b")
        #expect(directory.handles.sorted() == ["keyscribe", "keyscribe blue"])
    }

    @Test func conversationsAreFoundByPid() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        #expect(directory.conversation(pid: 10)?.id == "a")
        #expect(directory.conversation(pid: 99) == nil)
    }

    @Test func aRevisionTicksOnlyWhenSomethingChanged() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        let first = directory.revision
        directory.update(claude: [claude(10, "a")], live: [])
        #expect(directory.revision == first)
        directory.update(claude: [claude(10, "a", status: "busy")], live: [])
        #expect(directory.revision == first + 1)
    }
}
