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

    private func hosted(_ native: String, at start: Int?, cwd: String = "/src/keyscribe") -> AgentSession {
        AgentSession(
            agent: "claude", id: native, pid: nil, cwd: cwd, state: .idle, startedAt: start,
            host: AgentHostLocation(host: "example", instance: "/run/example.sock", native: native))
    }

    @Test func aConversationAHostOwnsIsListedWithItsLocationAndNoProcess() {
        var directory = AgentDirectory()
        directory.update(entries: [hosted("t1", at: 100), started(10, "a", at: 50, cwd: "/src/other").session], live: [])
        let conversation = directory.conversations.first { $0.id == "claude:t1" }
        #expect(conversation?.pid == nil)
        #expect(conversation?.host == AgentHostLocation(host: "example", instance: "/run/example.sock", native: "t1"))
        #expect(conversation?.handle == "keyscribe")
        #expect(directory.conversation(pid: 10)?.id == "claude:a")
    }

    @Test func statesSetOnRowsMatchTheRowsAFullUpdateBuildsAndCountOnceAsAChange() {
        func entries(_ a: AgentLiveState, _ b: AgentLiveState) -> [AgentSession] {
            var both = [started(10, "a", at: 50).session, started(11, "b", at: 60, cwd: "/src/other").session]
            both[0].state = a
            both[1].state = b
            return both
        }
        var patched = AgentDirectory()
        patched.update(entries: entries(.idle, .idle), live: ["claude:b"], excluded: ["claude:a"])
        let revision = patched.revision
        patched.setStates(["claude:a": .waitingApproval, "claude:b": .working, "claude:gone": .working])
        #expect(patched.revision == revision + 1)
        patched.setStates(["claude:a": .waitingApproval, "claude:b": .working])
        #expect(patched.revision == revision + 1)

        var rebuilt = AgentDirectory()
        rebuilt.update(entries: entries(.waitingApproval, .working), live: ["claude:b"], excluded: ["claude:a"])
        #expect(patched.conversations == rebuilt.conversations)
        #expect(patched.disconnected == rebuilt.disconnected)
    }

    private func crowd(_ tag: String, _ count: Int) -> [AgentSession] {
        (0..<count).map { k in
            started(20_000 + k, "\(tag)\(k)", at: k, cwd: "/src/\(tag)\(k)", name: "task \(tag) \(k / 2)").session
        }
    }

    private func handles(_ directory: AgentDirectory) -> [String: String] {
        Dictionary(uniqueKeysWithValues: directory.conversations.map { ($0.id, $0.handle) })
    }

    @Test func moreConversationsThanTheLimitLeavingTogetherAllComeBackWithTheirNames() {
        var directory = AgentDirectory()
        let everyone = crowd("a", AgentDirectory.retiredLimit + 20)
        directory.update(entries: everyone, live: [])
        #expect(directory.retired.isEmpty)
        let named = handles(directory)
        let suffixed = everyone.first { named["claude:\($0.id)"] != AgentHandles.normalize($0.explicitName ?? "") }
        #expect(suffixed != nil)
        directory.update(entries: [], live: [])
        #expect(directory.retired.count == everyone.count)

        directory.update(entries: [suffixed!], live: [])
        #expect(handles(directory) == ["claude:\(suffixed!.id)": named["claude:\(suffixed!.id)"]!])
        #expect(directory.retired.count == everyone.count - 1)
        directory.update(entries: everyone, live: [])
        #expect(handles(directory) == named)
        #expect(directory.retired.isEmpty)
    }

    @Test func aNewerCrowdLeavingEvictsAnOlderOneWholeAndNeverItself() {
        var directory = AgentDirectory()
        let older = crowd("a", 300), newer = crowd("b", 300)
        directory.update(entries: older, live: [])
        directory.update(entries: [], live: [])
        directory.update(entries: newer, live: [])
        directory.update(entries: [], live: [])
        #expect(Set(directory.retired.keys) == Set(newer.map { "claude:\($0.id)" }))
        #expect(directory.nativeNameById.keys.allSatisfy { directory.retired[$0] != nil })
    }

    @Test func theRememberedNamesKeptAlwaysMatchTheOnesWorkedOutFromTheDirectory() throws {
        var directory = AgentDirectory(remembered: ["claude:old": RememberedName(name: "old work", pid: 7, startedAt: 70, native: nil, agent: "claude")])
        #expect(directory.remembered == directory.rememberedNow())
        let entries = [started(10, "a", at: 50).session, started(11, "b", at: 60, cwd: "/src/other").session, started(7, "old", at: 70).session]
        let steps: [(String, (inout AgentDirectory) throws -> Void)] = [
            ("update", { $0.update(entries: entries, live: ["claude:a"]) }),
            ("setStates", { $0.setStates(["claude:a": .working]) }),
            ("rename", { try $0.rename("claude:a", to: "docs") }),
            ("carryChosenName", { _ = $0.carryChosenName(from: "claude:a", to: "claude:b", previous: ["older"]) }),
            ("useDefaultName", { $0.useDefaultName("claude:b") }),
            ("update after leaving", { $0.update(entries: [entries[0]], live: []) }),
        ]
        for (name, step) in steps {
            try step(&directory)
            #expect(directory.remembered == directory.rememberedNow(), "\(name)")
        }
    }

    @Test func aConversationListedBeforeItsFolderIsKnownGetsASayableNameThatTheFolderReplaces() {
        var directory = AgentDirectory()
        directory.update(entries: [hosted("t0", at: 50, cwd: "/src/keyscribe")], live: [])
        directory.update(entries: [hosted("t0", at: 50, cwd: "/src/keyscribe"), hosted("t1", at: 100, cwd: ""), hosted("t2", at: 200, cwd: "")], live: [])
        let early = directory.conversations.filter { $0.id != "claude:t0" }.map(\.handle).sorted()
        #expect(early == ["claude", "claude blue"])
        directory.update(entries: [hosted("t0", at: 50, cwd: "/src/keyscribe"), hosted("t1", at: 100), hosted("t2", at: 200, cwd: "")], live: [])
        #expect(directory.conversations.first { $0.id == "claude:t1" }?.handle == "keyscribe blue")
        #expect(directory.conversations.first { $0.id == "claude:t0" }?.handle == "keyscribe")
        #expect(directory.remembered["claude:t1"]?.name == "keyscribe blue")
    }

    @Test func aNameGivenBeforeTheFolderWasKnownIsNotRememberedSoARestartStillReplacesIt() throws {
        var before = AgentDirectory()
        before.update(entries: [hosted("t1", at: 100, cwd: "")], live: [])
        #expect(before.conversations.first?.handle == "claude")
        #expect(before.remembered["claude:t1"] == nil)
        before.update(entries: [], live: [], running: { _ in true })
        #expect(before.remembered["claude:t1"] == nil)
        var after = AgentDirectory(remembered: before.remembered)
        after.update(entries: [hosted("t1", at: 100, cwd: "")], live: [], running: { _ in true })
        after.update(entries: [hosted("t1", at: 100)], live: [], running: { _ in true })
        #expect(after.conversations.first?.handle == "keyscribe")
    }

    @Test func aNameGivenBeforeTheFolderWasKnownIsNotGivenBackAfterAScanThatMissedTheConversation() {
        var directory = AgentDirectory()
        directory.update(entries: [hosted("t1", at: 100, cwd: "")], live: [])
        directory.update(entries: [], live: [], running: { _ in true })
        directory.update(entries: [hosted("t1", at: 100)], live: [], running: { _ in true })
        #expect(directory.conversations.first?.handle == "keyscribe")
    }

    @Test func aNameTheUserChoseBeforeTodaysSpellingRulesIsKeptInTodaysSpelling() {
        let directory = AgentDirectory(chosen: ["claude:t1": "Build 2", "claude:t2": "  "])
        #expect(directory.chosenNames == ["claude:t1": "build two"])
    }

    @Test func aRememberedNameNoOneCanSayIsNotGivenBack() {
        let remembered = [
            "claude:t1": RememberedName(name: "", pid: nil, startedAt: 100, native: nil, agent: "claude"),
            "claude:t2": RememberedName(name: " blue", pid: nil, startedAt: 200, native: nil, agent: "claude"),
        ]
        var directory = AgentDirectory(remembered: remembered)
        directory.update(entries: [hosted("t1", at: 100), hosted("t2", at: 200)], live: [], running: { _ in true })
        #expect(directory.conversations.map(\.handle).sorted() == ["keyscribe", "keyscribe blue"])
    }

    @Test func aHostedConversationsRememberedNameSurvivesARestartAndNoOtherHostedConversationTakesIt() throws {
        var before = AgentDirectory()
        before.update(entries: [hosted("t1", at: 100)], live: [])
        before.update(entries: [hosted("t2", at: 100)], live: [], running: { _ in true })
        #expect(before.remembered["claude:t1"] == RememberedName(name: "keyscribe", pid: nil, startedAt: 100, native: nil, agent: "claude"))
        #expect(before.conversations.map(\.handle) != ["keyscribe"])
        let saved = try JSONEncoder().encode(before.remembered)
        #expect(String(decoding: saved, as: UTF8.self).contains("pid") == false)
        var after = AgentDirectory(remembered: try JSONDecoder().decode([String: RememberedName].self, from: saved))
        after.update(entries: [hosted("t1", at: 100), hosted("t2", at: 100)], live: [], running: { _ in true })
        #expect(after.conversations.first { $0.id == "claude:t1" }?.handle == "keyscribe")
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
        #expect(directory.remembered == [
            "claude:a": RememberedName(name: "backend", pid: 10, startedAt: 100, native: nil, agent: "claude", previous: ["keyscribe"]),
            "claude:b": RememberedName(name: "keyscribe blue", pid: 20, startedAt: 200, native: nil, agent: "claude"),
        ])
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

    @Test func aChosenNameMovesToTheConversationThatNowStandsForTheSameOneAndBack() throws {
        let inner = AgentSession(agent: "claude", id: "s1", pid: 10, cwd: "/src/keyscribe", state: .idle)
        let hosted = AgentSession(agent: "bb", id: "t1@/i", pid: nil, cwd: "/src/keyscribe", state: .idle)
        var directory = AgentDirectory()
        directory.update(entries: [inner], live: [])
        try directory.rename("claude:s1", to: "billing")
        directory.update(entries: [hosted], live: [])
        let moved1 = directory.carryChosenName(from: "claude:s1", to: "bb:t1@/i", previous: [])
        #expect(moved1)
        #expect(directory.conversation(handle: "billing")?.id == "bb:t1@/i")
        #expect(directory.chosenNames == ["bb:t1@/i": "billing"])
        directory.update(entries: [inner], live: [])
        let moved2 = directory.carryChosenName(from: "bb:t1@/i", to: "claude:s1", previous: [])
        #expect(moved2)
        #expect(directory.conversation(handle: "billing")?.id == "claude:s1")
        let moved3 = directory.carryChosenName(from: "bb:t1@/i", to: "claude:s1", previous: [])
        #expect(!moved3)
    }

    @Test func aChosenNameNeverReplacesOneTheOtherConversationAlreadyHas() throws {
        let one = AgentSession(agent: "claude", id: "s1", pid: 10, cwd: "/src/keyscribe", state: .idle)
        let two = AgentSession(agent: "bb", id: "t1@/i", pid: nil, cwd: "/src/site", state: .idle)
        var directory = AgentDirectory()
        directory.update(entries: [one, two], live: [])
        try directory.rename("claude:s1", to: "billing")
        try directory.rename("bb:t1@/i", to: "docs")
        let moved4 = directory.carryChosenName(from: "claude:s1", to: "bb:t1@/i", previous: [])
        #expect(!moved4)
        #expect(directory.conversation(handle: "docs")?.id == "bb:t1@/i")
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
