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

    @Test func aDisconnectedConversationKeepsItsNameAndNoOtherConversationTakesIt() {
        var directory = AgentDirectory()
        directory.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200)], live: [])
        let names = Dictionary(uniqueKeysWithValues: directory.conversations.map { ($0.id, $0.handle) })
        directory.update(entries: [started(10, "a", at: 100).session, started(20, "b", at: 200).session], live: [], excluded: ["claude:b"])
        #expect(directory.conversations.map(\.id) == ["claude:a"])
        #expect(directory.disconnected.map(\.id) == ["claude:b"])
        #expect(directory.disconnected.first?.handle == names["claude:b"])
        #expect(directory.conversations.first?.handle == names["claude:a"])
        #expect(directory.conversation(handle: names["claude:b"]!) == nil)
    }

    @Test func aDisconnectedConversationWhoseNameIsNoLongerReportedKeepsItEvenAfterARestart() {
        var directory = AgentDirectory()
        directory.update(entries: [started(10, "a", at: 100, name: "frontend").session, started(20, "b", at: 200).session], live: [])
        #expect(directory.conversation(pid: 10)?.handle == "frontend")
        directory.update(entries: [started(10, "a", at: 100).session, started(20, "b", at: 200).session], live: [], excluded: ["claude:a"])
        #expect(directory.disconnected.first?.handle == "frontend")
        var reopened = AgentDirectory(remembered: directory.remembered)
        reopened.update(entries: [started(10, "a", at: 100).session, started(20, "b", at: 200).session], live: [], excluded: ["claude:a"])
        #expect(reopened.disconnected.first?.handle == "frontend")
    }

    @Test func aConversationDisconnectedBeforeItWasNamedStillGetsItsOwnName() {
        var directory = AgentDirectory()
        directory.update(entries: [started(10, "a", at: 100).session, started(20, "b", at: 200).session], live: [], excluded: ["claude:a"])
        #expect(Set([directory.conversations.first?.handle, directory.disconnected.first?.handle]).count == 2)
    }

    @Test func aConversationCarriesItsRegistryStartAsADate() {
        var directory = AgentDirectory()
        directory.update(claude: [started(10, "a", at: 100_500), claude(20, "b")], live: [])
        #expect(directory.conversation(pid: 10)?.startedAt == Date(timeIntervalSince1970: 100.5))
        #expect(directory.conversation(pid: 20)?.startedAt == nil)
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
        #expect(before.conversation(handle: "keyscribe blue")?.id == "claude:b")
        for reused in [started(20, "b", at: 900), started(30, "b", at: 200)] {
            var after = AgentDirectory(remembered: before.remembered)
            after.update(claude: [reused], live: [])
            #expect(after.conversation(handle: "keyscribe")?.id == "claude:b")
        }
    }

    @Test func aClosedSessionsNameIsFreeForTheNextNewSession() {
        var before = AgentDirectory()
        before.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200)], live: [])
        var after = AgentDirectory(remembered: before.remembered)
        after.update(claude: [started(20, "b", at: 200), started(30, "c", at: 300)], live: [])
        #expect(after.conversation(handle: "keyscribe blue")?.id == "claude:b")
        #expect(after.conversation(handle: "keyscribe")?.id == "claude:c")
        #expect(Set(after.remembered.keys) == ["claude:b", "claude:c"])
    }

    @Test func onlyGeneratedNamesOfRunningSessionsWithAKnownStartAreRemembered() throws {
        var directory = AgentDirectory(chosen: ["claude:gone": "old"])
        directory.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200), claude(30, "c")], live: [])
        try directory.rename("claude:a", to: "backend")
        #expect(directory.remembered == ["claude:b": RememberedName(name: "keyscribe blue", pid: 20, startedAt: 200, native: nil, agent: "claude")])
    }

    @Test func aSessionMissingFromAStartupScanKeepsItsNameUntilItsProcessIsGone() {
        var before = AgentDirectory()
        before.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200)], live: [])
        var after = AgentDirectory(remembered: before.remembered)
        after.update(claude: [started(20, "b", at: 200), started(30, "c", at: 300)], live: [], running: { $0.pid == 10 })
        #expect(after.conversation(handle: "keyscribe blue")?.id == "claude:b")
        #expect(after.conversation(handle: "keyscribe")?.id == nil)
        #expect(after.remembered["claude:a"] == RememberedName(name: "keyscribe", pid: 10, startedAt: 100, native: nil, agent: "claude"))
        after.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200), started(30, "c", at: 300)], live: [], running: { $0.pid == 10 })
        #expect(after.conversation(handle: "keyscribe")?.id == "claude:a")
        #expect(Set(after.handles) == ["keyscribe", "keyscribe blue", "keyscribe green"])
    }

    @Test func aSessionThatDropsOutOfOneScanHoldsItsNameWhileItsProcessRuns() {
        var directory = AgentDirectory()
        directory.update(claude: [started(10, "a", at: 100)], live: [])
        directory.update(claude: [started(30, "c", at: 300)], live: [], running: { $0.pid == 10 })
        #expect(directory.conversation(handle: "keyscribe")?.id == nil)
        #expect(directory.remembered.keys.sorted() == ["claude:a", "claude:c"])
        directory.update(claude: [started(10, "a", at: 100), started(30, "c", at: 300)], live: [], running: { $0.pid == 10 })
        #expect(directory.conversation(handle: "keyscribe")?.id == "claude:a")
    }

    @Test func aMissingSessionWhoseProcessIsGoneFreesItsName() {
        var before = AgentDirectory()
        before.update(claude: [started(10, "a", at: 100)], live: [])
        var after = AgentDirectory(remembered: before.remembered)
        after.update(claude: [started(30, "c", at: 300)], live: [], running: { _ in false })
        #expect(after.conversation(handle: "keyscribe")?.id == "claude:c")
        #expect(after.remembered.keys.sorted() == ["claude:c"])
    }

    @Test func aNativeNameThatChangedWhileTheAppWasClosedIsUsedInsteadOfTheRememberedOne() {
        var before = AgentDirectory()
        before.update(claude: [started(10, "a", at: 100, name: "Fix login"), started(20, "b", at: 200, name: "Fix login")], live: [])
        #expect(before.conversation(handle: "fix login blue")?.id == "claude:b")
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
        #expect(directory.conversation(handle: "fix authentication retries")?.id == "claude:a")
        #expect(directory.conversation(handle: "api") == nil)
    }

    @Test func aKeyScribeOverrideWinsOverNativeNamesAndNativeRenames() throws {
        var directory = AgentDirectory(chosen: ["claude:a": "backend"])
        directory.update(claude: [named("a", "Fix authentication retries")], live: [])
        directory.update(claude: [named("a", "Fix cache invalidation")], live: [])
        #expect(directory.conversation(handle: "backend")?.id == "claude:a")
        #expect(directory.handles == ["backend"])
        try directory.rename("claude:a", to: "api")
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
        directory.update(claude: [named("a", "internal label", source: "derived")], live: [], titles: ["claude:a": "Generated title"])
        directory.update(claude: [named("a", "another internal label", source: "auto")], live: [], titles: ["claude:a": "Changed generated title"])
        #expect(directory.handles == ["api"])
    }

    @Test func nativeNamesAreAllocatedBeforeFolderFallbacksAndDuplicatesAreDistinct() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(20, "folder", cwd: "/src/backend"), named("b", "Backend"), named("a", "Backend")], live: [])
        #expect(directory.conversation(handle: "backend")?.id == "claude:a")
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
        #expect(directory.conversation(handle: "backend")?.id == "claude:folder")
        #expect(directory.handles.contains("backend blue"))
    }

    @Test func aNativeNameSurvivesResumeAndAForkGetsItsOwnHandle() {
        var directory = AgentDirectory()
        directory.update(claude: [named("a", "Authentication")], live: [])
        directory.update(claude: [named("a", "Authentication"), named("fork", "Authentication")], live: [])
        let fork = directory.conversations.first { $0.id == "claude:fork" }?.handle
        directory.update(claude: [], live: [])
        directory.update(claude: [named("fork", "Authentication")], live: [])
        #expect(directory.conversations.first?.handle == fork)
        directory.update(claude: [named("fork", "Authentication"), named("a", "Authentication")], live: [])
        #expect(directory.conversation(handle: "authentication")?.id == "claude:a")
    }

    @Test func nativeNamesCannotClaimReservedRowSyntaxOrAnAwayOverride() {
        var directory = AgentDirectory(chosen: ["away": "backend"])
        directory.update(claude: [named("a", "Backend"), named("b", "session two")], live: [])
        #expect(directory.handles.contains("backend blue"))
        #expect(directory.handles.contains("api"))
    }

    @Test func aConversationCarriesTheTitleItsConnectorReported() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a"), claude(11, "b")], live: ["claude:a", "claude:b"], titles: ["claude:a": "Fix terminal focus"])
        let byId = Dictionary(uniqueKeysWithValues: directory.conversations.map { ($0.id, $0) })
        #expect(byId["claude:a"]?.title == "Fix terminal focus")
        #expect(byId["claude:b"]?.title == nil)
    }

    @Test func registrySessionsBecomeConversationsWithHandles() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a"), claude(11, "b"), claude(12, "c", cwd: "/src/chatplay")], live: ["claude:a", "claude:b"])
        let byId = Dictionary(uniqueKeysWithValues: directory.conversations.map { ($0.id, $0) })
        #expect(byId["claude:a"]?.handle == "keyscribe")
        #expect(byId["claude:b"]?.handle == "keyscribe blue")
        #expect(byId["claude:c"]?.handle == "chatplay")
        #expect(byId["claude:a"]?.connectorLive == true)
        #expect(byId["claude:c"]?.connectorLive == false)
        #expect(byId["claude:c"]?.state == .idle)
    }

    @Test func aNameStaysWithItsConversationWhenTheTerminalSwitchesToAnother() throws {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        try directory.rename("claude:a", to: "backend")
        directory.update(claude: [claude(10, "a2")], live: [])
        #expect(directory.conversation(handle: "backend") == nil)
        #expect(directory.conversation(pid: 10)?.handle == "keyscribe")
        directory.update(claude: [claude(10, "a")], live: [])
        #expect(directory.conversation(handle: "backend")?.id == "claude:a")
    }

    @Test func aChosenNameStaysReservedForItsConversationWhileItIsAway() throws {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        try directory.rename("claude:a", to: "backend")
        directory.update(claude: [claude(20, "b", cwd: "/src/backend")], live: [])
        #expect(directory.conversation(pid: 20)?.handle == "backend blue")
        directory.update(claude: [claude(20, "b", cwd: "/src/backend"), claude(10, "a")], live: [])
        #expect(directory.conversation(handle: "backend")?.id == "claude:a")
    }

    @Test func nobodyElseCanTakeAChosenNameWhileItsConversationIsAway() throws {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        try directory.rename("claude:a", to: "backend")
        directory.update(claude: [claude(20, "b")], live: [])
        #expect(throws: AgentHandles.RenameError.taken) { try directory.rename("claude:b", to: "Back End") }
    }

    @Test func aReturningConversationNeverTakesBackANameSomeoneElseChose() throws {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a", cwd: "/src/api")], live: [])
        directory.update(claude: [], live: [])
        directory.update(claude: [claude(20, "b", cwd: "/src/api")], live: [])
        try directory.rename("claude:b", to: "api")
        directory.update(claude: [], live: [])
        directory.update(claude: [claude(10, "a", cwd: "/src/api")], live: [])
        #expect(directory.conversation(pid: 10)?.handle == "api blue")
        directory.update(claude: [claude(10, "a", cwd: "/src/api"), claude(20, "b", cwd: "/src/api")], live: [])
        #expect(directory.conversation(handle: "api")?.id == "claude:b")
    }

    @Test func chosenNamesComeBackAfterARestartEvenWhenTheyWereSwapped() throws {
        var before = AgentDirectory()
        let sessions = [claude(10, "a", cwd: "/src/api"), claude(20, "b", cwd: "/src/docs")]
        before.update(claude: sessions, live: [])
        try before.rename("claude:a", to: "backend")
        try before.rename("claude:b", to: "api")

        var after = AgentDirectory(chosen: before.chosenNames)
        after.update(claude: sessions, live: [])
        #expect(after.conversation(handle: "backend")?.id == "claude:a")
        #expect(after.conversation(handle: "api")?.id == "claude:b")
    }

    @Test func aRestoredChosenNameStaysReservedUntilItsConversationReturns() {
        var directory = AgentDirectory(chosen: ["claude:a": "api"])
        directory.update(claude: [claude(20, "b", cwd: "/src/api")], live: [])
        #expect(directory.conversation(pid: 20)?.handle == "api blue")
        directory.update(claude: [claude(20, "b", cwd: "/src/api"), claude(10, "a", cwd: "/src/other")], live: [])
        #expect(directory.conversation(handle: "api")?.id == "claude:a")
    }

    @Test func aGeneratedNameIsReusedWhileItsConversationIsAway() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        directory.update(claude: [claude(10, "a2")], live: [])
        #expect(directory.conversation(handle: "keyscribe")?.id == "claude:a2")
        var switching = AgentDirectory()
        switching.update(claude: [started(10, "a", at: 100)], live: [], running: { _ in true })
        for next in ["a2", "a3", "a4"] {
            switching.update(claude: [started(10, next, at: 100)], live: [], running: { _ in true })
            #expect(switching.conversation(handle: "keyscribe")?.id == "claude:" + next)
            #expect(switching.remembered.keys.sorted() == ["claude:" + next])
        }
    }

    @Test func aNameHeldForAMissingRunningSessionCannotBeTakenByARename() {
        var directory = AgentDirectory()
        directory.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200)], live: [])
        directory.update(claude: [started(20, "b", at: 200)], live: [], running: { $0.pid == 10 })
        #expect(throws: AgentHandles.RenameError.taken) { try directory.rename("claude:b", to: "keyscribe") }
        #expect(directory.renameProblem("claude:b", to: "Keyscribe") == .taken)
        #expect(directory.renameProblem("claude:b", to: "backend") == nil)
        #expect(directory.renameProblem("claude:b", to: "session 2") == .reserved)
        directory.update(claude: [started(10, "a", at: 100), started(20, "b", at: 200)], live: [], running: { $0.pid == 10 })
        #expect(directory.conversation(handle: "keyscribe")?.id == "claude:a")
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
        try directory.rename("claude:a", to: "Backend")
        directory.update(claude: [claude(10, "a", status: "busy")], live: [])
        #expect(directory.conversation(handle: "backend")?.state == .working)
        #expect(directory.conversation(handle: "keyscribe") == nil)
    }

    @Test func handlesAreLookedUpBySpokenForm() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a"), claude(11, "b")], live: [])
        #expect(directory.conversation(handle: "KeyscribeBlue")?.id == "claude:b")
        #expect(directory.handles.sorted() == ["keyscribe", "keyscribe blue"])
    }

    @Test func conversationsAreFoundByPid() {
        var directory = AgentDirectory()
        directory.update(claude: [claude(10, "a")], live: [])
        #expect(directory.conversation(pid: 10)?.id == "claude:a")
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
