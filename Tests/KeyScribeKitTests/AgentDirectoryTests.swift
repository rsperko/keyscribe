import Foundation
import Testing
@testable import KeyScribeKit

struct AgentDirectoryTests {
    private func claude(_ pid: Int, _ session: String, cwd: String = "/src/keyscribe", status: String = "idle", waitingFor: String? = nil) -> ClaudeRegistryEntry {
        ClaudeRegistryEntry(pid: pid, sessionId: session, cwd: cwd, name: nil, status: status, waitingFor: waitingFor)
    }

    private func started(_ pid: Int, _ session: String, at start: Int, cwd: String = "/src/keyscribe", name: String? = nil) -> ClaudeRegistryEntry {
        ClaudeRegistryEntry(pid: pid, sessionId: session, cwd: cwd, name: name, status: "idle", waitingFor: nil, nameSource: name == nil ? nil : "user", startedAt: start)
    }

    @Test func generatedNamesComeBackToTheSameRunningSessionsWhateverOrderTheyAreFoundIn() {
        var before = AgentDirectory()
        before.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200)], live: [])
        let names = Dictionary(uniqueKeysWithValues: before.conversations.map { ($0.id, $0.handle) })
        var after = AgentDirectory(remembered: before.remembered)
        after.update(claude: [started(20, "b", at: 200), started(10, "a", at: 100)], live: [])
        #expect(Dictionary(uniqueKeysWithValues: after.conversations.map { ($0.id, $0.handle) }) == names)
        var fresh = AgentDirectory()
        fresh.update(claude: [started(20, "b", at: 200), started(10, "a", at: 100)], live: [])
        #expect(Dictionary(uniqueKeysWithValues: fresh.conversations.map { ($0.id, $0.handle) }) != names)
    }

    @Test func aRememberedNameIsNotGivenBackToAnotherProcess() {
        var before = AgentDirectory()
        before.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200)], live: [])
        #expect(before.conversation(handle: "keyscribe blue")?.id == "b")
        for reused in [started(20, "b", at: 900), started(30, "b", at: 200)] {
            var after = AgentDirectory(remembered: before.remembered)
            after.update(claude: [reused], live: [])
            #expect(after.conversation(handle: "keyscribe")?.id == "b")
        }
    }

    @Test func aClosedSessionsNameIsFreeForTheNextNewSession() {
        var before = AgentDirectory()
        before.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200)], live: [])
        var after = AgentDirectory(remembered: before.remembered)
        after.update(claude: [started(20, "b", at: 200), started(30, "c", at: 300)], live: [])
        #expect(after.conversation(handle: "keyscribe blue")?.id == "b")
        #expect(after.conversation(handle: "keyscribe")?.id == "c")
        #expect(Set(after.remembered.keys) == ["b", "c"])
    }

    @Test func onlyGeneratedNamesOfRunningSessionsWithAKnownStartAreRemembered() throws {
        var directory = AgentDirectory(chosen: ["gone": "old"])
        directory.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200), claude(30, "c")], live: [])
        try directory.rename("a", to: "backend")
        #expect(directory.remembered == ["b": RememberedName(name: "keyscribe blue", pid: 20, startedAt: 200, native: nil)])
    }

    @Test func aSessionMissingFromAStartupScanKeepsItsNameUntilItsProcessIsGone() {
        var before = AgentDirectory()
        before.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200)], live: [])
        var after = AgentDirectory(remembered: before.remembered)
        after.update(claude: [started(20, "b", at: 200), started(30, "c", at: 300)], live: [], running: { $0.pid == 10 })
        #expect(after.conversation(handle: "keyscribe blue")?.id == "b")
        #expect(after.conversation(handle: "keyscribe")?.id == nil)
        #expect(after.remembered["a"] == RememberedName(name: "keyscribe", pid: 10, startedAt: 100, native: nil))
        after.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200), started(30, "c", at: 300)], live: [], running: { $0.pid == 10 })
        #expect(after.conversation(handle: "keyscribe")?.id == "a")
        #expect(Set(after.handles) == ["keyscribe", "keyscribe blue", "keyscribe green"])
    }

    @Test func aSessionThatDropsOutOfOneScanHoldsItsNameWhileItsProcessRuns() {
        var directory = AgentDirectory()
        directory.update(claude: [started(10, "a", at: 100)], live: [])
        directory.update(claude: [started(30, "c", at: 300)], live: [], running: { $0.pid == 10 })
        #expect(directory.conversation(handle: "keyscribe")?.id == nil)
        #expect(directory.remembered.keys.sorted() == ["a", "c"])
        directory.update(claude: [started(10, "a", at: 100), started(30, "c", at: 300)], live: [], running: { $0.pid == 10 })
        #expect(directory.conversation(handle: "keyscribe")?.id == "a")
    }

    @Test func aMissingSessionWhoseProcessIsGoneFreesItsName() {
        var before = AgentDirectory()
        before.update(claude: [started(10, "a", at: 100)], live: [])
        var after = AgentDirectory(remembered: before.remembered)
        after.update(claude: [started(30, "c", at: 300)], live: [], running: { _ in false })
        #expect(after.conversation(handle: "keyscribe")?.id == "c")
        #expect(after.remembered.keys.sorted() == ["c"])
    }

    @Test func aNativeNameThatChangedWhileTheAppWasClosedIsUsedInsteadOfTheRememberedOne() {
        var before = AgentDirectory()
        before.update(claude: [started(10, "a", at: 100, name: "Fix login"), started(20, "b", at: 200, name: "Fix login")], live: [])
        #expect(before.conversation(handle: "fix login blue")?.id == "b")
        var same = AgentDirectory(remembered: before.remembered)
        same.update(claude: [started(20, "b", at: 200, name: "Fix login")], live: [])
        #expect(same.handles == ["fix login blue"])
        var renamed = AgentDirectory(remembered: before.remembered)
        renamed.update(claude: [started(20, "b", at: 200, name: "Fix cache")], live: [])
        #expect(renamed.handles == ["fix cache"])
    }

    private func named(_ id: String, _ name: String, source: String = "user", cwd: String = "/src/api") -> ClaudeRegistryEntry {
        ClaudeRegistryEntry(pid: 10, sessionId: id, cwd: cwd, name: name, status: "idle", waitingFor: nil, nameSource: source)
    }

    @Test func anExplicitAgentNameIsUsedBeforeTheFolder() {
        var directory = AgentDirectory()
        directory.update(claude: [named("a", "Fix authentication retries")], live: [])
        #expect(directory.conversation(handle: "fix authentication retries")?.id == "a")
        #expect(directory.conversation(handle: "api") == nil)
    }

    @Test func aKeyScribeOverrideWinsOverNativeNamesAndNativeRenames() throws {
        var directory = AgentDirectory(chosen: ["a": "backend"])
        directory.update(claude: [named("a", "Fix authentication retries")], live: [])
        directory.update(claude: [named("a", "Fix cache invalidation")], live: [])
        #expect(directory.conversation(handle: "backend")?.id == "a")
        #expect(directory.handles == ["backend"])
        try directory.rename("a", to: "api")
        directory.update(claude: [named("a", "Another native name")], live: [])
        #expect(directory.handles == ["api"])
    }

    @Test func aNativeNameArrivingOrChangingUpdatesAnUnaliasedConversation() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a", cwd: "/src/api")], live: [])
        directory.update(claude: [named("a", "Fix authentication retries")], live: [])
        #expect(directory.handles == ["fix authentication retries"])
        directory.update(claude: [named("a", "Fix cache invalidation")], live: [])
        #expect(directory.handles == ["fix cache invalidation"])
        directory.update(claude: [named("a", "internal label", source: "derived")], live: [])
        #expect(directory.handles == ["api"])
    }

    @Test func generatedTitlesAndDerivedRegistryNamesNeverBecomeAddresses() {
        var directory = AgentDirectory()
        directory.update(claude: [named("a", "internal label", source: "derived")], live: [], titles: ["a": "Generated title"])
        directory.update(claude: [named("a", "another internal label", source: "auto")], live: [], titles: ["a": "Changed generated title"])
        #expect(directory.handles == ["api"])
    }

    @Test func nativeNamesAreAllocatedBeforeFolderFallbacksAndDuplicatesAreDistinct() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(20, "folder", cwd: "/src/backend"), named("b", "Backend"), named("a", "Backend")], live: [])
        #expect(directory.conversation(handle: "backend")?.id == "a")
        #expect(Set(directory.handles).count == 3)
        #expect(directory.conversation(pid: 20)?.handle != "backend")
        let handles = directory.conversations.map { ($0.id, $0.handle) }
        directory.update(claude: [named("a", "Backend"), claude(20, "folder", cwd: "/src/backend"), named("b", "Backend")], live: [])
        #expect(Dictionary(uniqueKeysWithValues: directory.conversations.map { ($0.id, $0.handle) }) == Dictionary(uniqueKeysWithValues: handles))
    }

    @Test func aNativeRenameNeverStealsAnotherConversationsHandle() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(20, "folder", cwd: "/src/backend"), named("a", "Authentication")], live: [])
        directory.update(claude: [claude(20, "folder", cwd: "/src/backend"), named("a", "Backend")], live: [])
        #expect(directory.conversation(handle: "backend")?.id == "folder")
        #expect(directory.handles.contains("backend blue"))
    }

    @Test func aNativeNameSurvivesResumeAndAForkGetsItsOwnHandle() {
        var directory = AgentDirectory()
        directory.update(claude: [named("a", "Authentication")], live: [])
        directory.update(claude: [named("a", "Authentication"), named("fork", "Authentication")], live: [])
        let fork = directory.conversations.first { $0.id == "fork" }?.handle
        directory.update(claude: [], live: [])
        directory.update(claude: [named("fork", "Authentication")], live: [])
        #expect(directory.conversations.first?.handle == fork)
        directory.update(claude: [named("fork", "Authentication"), named("a", "Authentication")], live: [])
        #expect(directory.conversation(handle: "authentication")?.id == "a")
    }

    @Test func nativeNamesCannotClaimReservedRowSyntaxOrAnAwayOverride() {
        var directory = AgentDirectory(chosen: ["away": "backend"])
        directory.update(claude: [named("a", "Backend"), named("b", "session two")], live: [])
        #expect(directory.handles.contains("backend blue"))
        #expect(directory.handles.contains("api"))
    }

    @Test func aConversationCarriesTheTitleItsConnectorReported() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a"), claude(11, "b")], live: ["a", "b"], titles: ["a": "Fix terminal focus"])
        let byId = Dictionary(uniqueKeysWithValues: directory.conversations.map { ($0.id, $0) })
        #expect(byId["a"]?.title == "Fix terminal focus")
        #expect(byId["b"]?.title == nil)
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

    @Test func chosenNamesComeBackAfterARestartEvenWhenTheyWereSwapped() throws {
        var before = AgentDirectory()
        let sessions = [claude(10, "a", cwd: "/src/api"), claude(20, "b", cwd: "/src/docs")]
        before.update(claude: sessions, live: [])
        try before.rename("a", to: "backend")
        try before.rename("b", to: "api")

        var after = AgentDirectory(chosen: before.chosenNames)
        after.update(claude: sessions, live: [])
        #expect(after.conversation(handle: "backend")?.id == "a")
        #expect(after.conversation(handle: "api")?.id == "b")
    }

    @Test func aRestoredChosenNameStaysReservedUntilItsConversationReturns() {
        var directory = AgentDirectory(chosen: ["a": "api"])
        directory.update(claude: [claude(20, "b", cwd: "/src/api")], live: [])
        #expect(directory.conversation(pid: 20)?.handle == "api blue")
        directory.update(claude: [claude(20, "b", cwd: "/src/api"), claude(10, "a", cwd: "/src/other")], live: [])
        #expect(directory.conversation(handle: "api")?.id == "a")
    }

    @Test func aGeneratedNameIsReusedWhileItsConversationIsAway() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        directory.update(claude: [claude(10, "a2")], live: [])
        #expect(directory.conversation(handle: "keyscribe")?.id == "a2")
        var switching = AgentDirectory()
        switching.update(claude: [started(10, "a", at: 100)], live: [], running: { _ in true })
        for next in ["a2", "a3", "a4"] {
            switching.update(claude: [started(10, next, at: 100)], live: [], running: { _ in true })
            #expect(switching.conversation(handle: "keyscribe")?.id == next)
            #expect(switching.remembered.keys.sorted() == [next])
        }
    }

    @Test func aNameHeldForAMissingRunningSessionCannotBeTakenByARename() {
        var directory = AgentDirectory()
        directory.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200)], live: [])
        directory.update(claude: [started(20, "b", at: 200)], live: [], running: { $0.pid == 10 })
        #expect(throws: AgentHandles.RenameError.taken) { try directory.rename("b", to: "keyscribe") }
        #expect(directory.renameProblem("b", to: "Keyscribe") == .taken)
        #expect(directory.renameProblem("b", to: "backend") == nil)
        #expect(directory.renameProblem("b", to: "session 2") == .reserved)
        directory.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200)], live: [], running: { $0.pid == 10 })
        #expect(directory.conversation(handle: "keyscribe")?.id == "a")
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
