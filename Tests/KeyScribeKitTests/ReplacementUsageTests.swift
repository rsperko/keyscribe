import Foundation
import Testing
@testable import KeyScribeKit

struct ReplacementUsageTests {
    private let globalRule = ReplacementRule(heard: "Slash Resume", replace: "/resume", isRegex: false, origin: .global)
    private let modeRegex = ReplacementRule(heard: #"\bFoo\b"#, replace: "bar", isRegex: true, origin: .mode("code"))
    private let globalKey = "global|l|slash resume"
    private let modeKey = #"mode:code|r|\bFoo\b"#

    @Test func literalKeysFoldCaseAndRegexKeysStayExact() {
        #expect(ReplacementUsage.key(origin: .global, heard: "Slash Resume", isRegex: false) == globalKey)
        #expect(ReplacementUsage.key(origin: .mode("code"), heard: #"\bFoo\b"#, isRegex: true) == modeKey)
    }

    @Test func aRuleWithoutAnOriginHasNoKey() {
        #expect(ReplacementUsage.key(for: ReplacementRule(heard: "a", replace: "b", isRegex: false)) == nil)
    }

    @Test func rulesPresentWhenTrackingBeginsHaveNoKnownAddDate() {
        let usage = ReplacementUsage().reconciled(with: [globalKey], on: "2026-10-21")
        #expect(usage.trackingSince == "2026-10-21")
        #expect(usage.rules == [globalKey: .init(count: 0, lastUsed: nil, since: nil)])
    }

    @Test func rulesAddedAfterTrackingBeganRecordTheDayTheyAppeared() {
        let usage = ReplacementUsage()
            .reconciled(with: [globalKey], on: "2026-10-01")
            .reconciled(with: [globalKey, modeKey], on: "2026-10-21")
        #expect(usage.trackingSince == "2026-10-01")
        #expect(usage.rules[globalKey]?.since == nil)
        #expect(usage.rules[modeKey] == .init(count: 0, lastUsed: nil, since: "2026-10-21"))
    }

    @Test func reconcilingDropsRulesNoLongerConfigured() {
        let usage = ReplacementUsage()
            .reconciled(with: [globalKey, modeKey], on: "2026-10-01")
            .reconciled(with: [modeKey], on: "2026-10-21")
        #expect(Set(usage.rules.keys) == [modeKey])
    }

    @Test func recordingCountsEachConfiguredRuleOncePerDictation() {
        let usage = ReplacementUsage()
            .reconciled(with: [globalKey, modeKey], on: "2026-10-01")
            .recording([globalRule, globalRule, modeRegex], on: "2026-10-21")
        #expect(usage.rules[globalKey] == .init(count: 1, lastUsed: "2026-10-21", since: nil))
        #expect(usage.rules[modeKey]?.count == 1)
    }

    @Test func recordingAgainKeepsSinceAndMovesLastUsed() {
        let usage = ReplacementUsage()
            .reconciled(with: [], on: "2026-08-01")
            .reconciled(with: [globalKey], on: "2026-08-02")
            .recording([globalRule], on: "2026-10-19")
            .recording([globalRule], on: "2026-10-21")
        #expect(usage.rules[globalKey] == .init(count: 2, lastUsed: "2026-10-21", since: "2026-08-02"))
    }

    @Test func onceTrackingHasBegunARuleNoLongerConfiguredIsNotRecorded() {
        let usage = ReplacementUsage()
            .reconciled(with: [modeKey], on: "2026-10-01")
            .recording([globalRule], on: "2026-10-21")
        #expect(usage.rules[globalKey] == nil)
    }

    @Test func beforeTrackingBeginsARecordedRuleIsKeptWithNoKnownAddDate() {
        let usage = ReplacementUsage().recording([globalRule], on: "2026-10-21")
        #expect(usage.rules[globalKey] == .init(count: 1, lastUsed: "2026-10-21", since: nil))
        #expect(usage.trackingSince == nil)
    }

    @Test func recordingIgnoresRulesWithoutAnOrigin() {
        let usage = ReplacementUsage().recording([ReplacementRule(heard: "a", replace: "b", isRegex: false)], on: "2026-10-21")
        #expect(usage.rules.isEmpty)
    }

    @Test func reconcilingKeepsExistingEntriesUntouched() {
        let before = ReplacementUsage()
            .reconciled(with: [globalKey], on: "2026-10-01")
            .recording([globalRule], on: "2026-10-02")
        #expect(before.reconciled(with: [globalKey], on: "2026-10-21") == before)
    }

    @Test func configuredKeysCoverGlobalAndEachModesOwnRules() {
        var code = Mode(id: "code", name: "Code")
        code.replacements = .init(includeGlobal: true, rules: [.init(heard: #"\bFoo\b"#, replace: "bar", regex: true)])
        let keys = ReplacementUsage.configuredKeys(
            global: ReplacementsSet(rules: [.init(heard: "Slash Resume", replace: "/resume", regex: false)]),
            modes: [code, Mode(id: "notes", name: "Notes")])
        #expect(keys == [globalKey, modeKey])
    }

    @Test func renamingAModeMovesOnlyThatModesEntries() {
        let usage = ReplacementUsage()
            .reconciled(with: [globalKey, modeKey], on: "2026-10-01")
            .recording([globalRule, modeRegex], on: "2026-10-21")
            .renamingMode("code", to: "coding")
        #expect(Set(usage.rules.keys) == [globalKey, #"mode:coding|r|\bFoo\b"#])
        #expect(usage.rules[#"mode:coding|r|\bFoo\b"#]?.count == 1)
    }

    @Test func entryLooksUpAConfiguredRuleInItsScope() {
        let usage = ReplacementUsage().reconciled(with: [modeKey], on: "2026-10-21")
        let rule = ReplacementsSet.Rule(heard: #"\bFoo\b"#, replace: "baz", regex: true)
        #expect(usage.entry(for: rule, in: .mode("code")) != nil)
        #expect(usage.entry(for: rule, in: .global) == nil)
    }

    @Test func encodingRoundTrips() {
        let usage = ReplacementUsage()
            .reconciled(with: [globalKey], on: "2026-10-01")
            .reconciled(with: [globalKey, modeKey], on: "2026-10-02")
            .recording([globalRule], on: "2026-10-21")
        #expect(ReplacementUsage(decoding: usage.encoded()) == usage)
    }

    @Test func unreadableDataReadsAsEmpty() {
        #expect(ReplacementUsage(decoding: Data("not json".utf8)) == ReplacementUsage())
        #expect(ReplacementUsage(decoding: Data(#"{"schemaVersion":99,"rules":{}}"#.utf8)) == ReplacementUsage())
    }
}

struct ReplacementUsageStoreTests {
    private let teh = ReplacementRule(heard: "teh", replace: "the", isRegex: false, origin: .global)

    private func temporaryDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func recordedUsagePersistsUnderTheUsageDirectory() {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ReplacementUsageStore(supportDir: dir)
        store.reconcile(keys: ["global|l|teh"], today: "2026-10-01")
        store.record([teh], today: "2026-10-21")
        store.flush()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("usage/replacements.json").path))
        #expect(ReplacementUsageStore(supportDir: dir).snapshot().rules["global|l|teh"]?.count == 1)
    }

    @Test func aDictationWithNoCountedRulesWritesNothing() {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ReplacementUsageStore(supportDir: dir)
        store.record([ReplacementRule(heard: "teh", replace: "the", isRegex: false)], today: "2026-10-21")
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("usage").path))
    }

    @Test func reconcileAndRenameUpdateTheStoredUsage() {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ReplacementUsageStore(supportDir: dir)
        store.reconcile(keys: [], today: "2026-09-01")
        store.reconcile(keys: ["mode:code|l|teh"], today: "2026-10-01")
        store.renameMode("code", to: "coding")
        store.flush()
        #expect(ReplacementUsageStore(supportDir: dir).snapshot().rules
            == ["mode:coding|l|teh": .init(count: 0, lastUsed: nil, since: "2026-10-01")])
    }

    private func codeRule(_ id: String) -> ReplacementRule {
        ReplacementRule(heard: "teh", replace: "the", isRegex: false, origin: .mode(id))
    }

    @Test func aDictationThatStartedBeforeARenameCountsTowardTheRenamedMode() {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ReplacementUsageStore(supportDir: dir)
        store.reconcile(keys: ["mode:code|l|teh"], today: "2026-10-01")
        let captured = store.renameEpoch()
        store.renameMode("code", to: "notes")
        store.renameMode("notes", to: "coding")
        store.reconcile(keys: ["mode:coding|l|teh"], today: "2026-10-01")
        store.record([codeRule("code")], capturedAt: captured, today: "2026-10-21")
        store.flush()
        #expect(store.snapshot().rules == ["mode:coding|l|teh": .init(count: 1, lastUsed: "2026-10-21", since: nil)])
    }

    @Test func aModeCreatedWithARenamedModesOldIdKeepsItsOwnUses() {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ReplacementUsageStore(supportDir: dir)
        store.reconcile(keys: ["mode:code|l|teh"], today: "2026-10-01")
        store.renameMode("code", to: "coding")
        store.reconcile(keys: ["mode:coding|l|teh", "mode:code|l|teh"], today: "2026-10-02")
        store.record([codeRule("code")], capturedAt: store.renameEpoch(), today: "2026-10-21")
        store.flush()
        #expect(store.snapshot().rules["mode:code|l|teh"]?.count == 1)
        #expect(store.snapshot().rules["mode:coding|l|teh"]?.count == 0)
    }

    @Test func aModeRenamedAndRenamedBackKeepsItsUses() {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ReplacementUsageStore(supportDir: dir)
        store.reconcile(keys: ["mode:code|l|teh"], today: "2026-10-01")
        let beforeBoth = store.renameEpoch()
        store.renameMode("code", to: "coding")
        let between = store.renameEpoch()
        store.renameMode("coding", to: "code")
        store.record([codeRule("code")], capturedAt: beforeBoth, today: "2026-10-21")
        store.record([codeRule("coding")], capturedAt: between, today: "2026-10-21")
        store.record([codeRule("code")], capturedAt: store.renameEpoch(), today: "2026-10-21")
        store.flush()
        #expect(store.snapshot().rules == ["mode:code|l|teh": .init(count: 3, lastUsed: "2026-10-21", since: nil)])
    }

    @Test func aDictationThatStartedBeforeARuleWasRemovedDoesNotBringItBack() {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ReplacementUsageStore(supportDir: dir)
        store.reconcile(keys: ["global|l|teh"], today: "2026-10-01")
        store.reconcile(keys: [], today: "2026-10-21")
        store.record([teh], today: "2026-10-21")
        store.flush()
        #expect(store.snapshot().rules.isEmpty)
    }

    @Test(arguments: ["not json", #"{"schemaVersion":99,"rules":{}}"#])
    func anUnreadableFileIsMovedAsideAndCountingStartsFresh(_ contents: String) throws {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usageDir = dir.appendingPathComponent(ReplacementUsageStore.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: usageDir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: usageDir.appendingPathComponent(ReplacementUsageStore.fileName))
        let reported = FailureCount()
        let store = ReplacementUsageStore(supportDir: dir, onUnreadableFile: { _ in reported.increment() })

        #expect(store.snapshot() == ReplacementUsage())
        #expect(reported.value == 1)
        let aside = usageDir.appendingPathComponent(ReplacementUsageStore.fileName + ".unreadable")
        #expect(try String(contentsOf: aside, encoding: .utf8) == contents)

        store.reconcile(keys: ["global|l|teh"], today: "2026-10-21")
        store.flush()
        #expect(ReplacementUsageStore(supportDir: dir).snapshot().rules["global|l|teh"] != nil)
        #expect(try String(contentsOf: aside, encoding: .utf8) == contents)
        #expect(reported.value == 1)
    }

    @Test func anUnreadableFileThatCannotBeMovedIsNeverWrittenOver() throws {
        let dir = temporaryDir()
        let usageDir = dir.appendingPathComponent(ReplacementUsageStore.directoryName, isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: usageDir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: usageDir, withIntermediateDirectories: true)
        let file = usageDir.appendingPathComponent(ReplacementUsageStore.fileName)
        try Data("not json".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: usageDir.path)
        let store = ReplacementUsageStore(supportDir: dir)
        store.reconcile(keys: ["global|l|teh"], today: "2026-10-21")
        store.flush()
        #expect(store.snapshot().rules["global|l|teh"] != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: usageDir.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
    }

    @Test func aMissingFileIsNotReportedAsUnreadable() {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reported = FailureCount()
        let store = ReplacementUsageStore(supportDir: dir, onUnreadableFile: { _ in reported.increment() })
        #expect(store.snapshot() == ReplacementUsage())
        #expect(reported.value == 0)
    }

    @Test func aFailedWriteIsReportedAndRetriedOnTheNextChange() throws {
        let dir = temporaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent(ReplacementUsageStore.directoryName)
        try Data().write(to: blocker)
        let failures = FailureCount()
        let store = ReplacementUsageStore(supportDir: dir, onWriteFailure: { _ in failures.increment() })
        store.reconcile(keys: ["global|l|teh"], today: "2026-10-01")
        store.flush()
        #expect(failures.value == 1)

        try FileManager.default.removeItem(at: blocker)
        store.reconcile(keys: ["global|l|teh"], today: "2026-10-01")
        store.flush()
        #expect(failures.value == 1)
        #expect(ReplacementUsageStore(supportDir: dir).snapshot().rules["global|l|teh"] != nil)
    }
}

private final class FailureCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

struct ReplacementUsageCaptionTests {
    private func caption(_ entry: ReplacementUsage.Entry?, trackingSince: String? = "2026-08-01") -> String? {
        ReplacementUsageCaption.text(
            for: entry, trackingSince: trackingSince, today: "2026-10-21", locale: Locale(identifier: "en_US"))
    }

    @Test func anUntrackedRuleHasNoCaption() {
        #expect(caption(nil) == nil)
    }

    @Test func anUnusedRuleAddedSinceTrackingBeganSaysWhenItWasAdded() {
        #expect(caption(.init(count: 0, lastUsed: nil, since: "2026-10-21")) == "Added today")
        #expect(caption(.init(count: 0, lastUsed: nil, since: "2026-08-02")) == "Not used since added Aug 2")
        #expect(caption(.init(count: 0, lastUsed: nil, since: "2025-12-30"), trackingSince: "2025-12-01")
            == "Not used since added Dec 30, 2025")
    }

    @Test func anUnusedRuleThatPredatesTrackingNeverClaimsAnAddDate() {
        #expect(caption(.init(count: 0, lastUsed: nil, since: nil)) == "No uses recorded since Aug 1")
        #expect(caption(.init(count: 0, lastUsed: nil, since: nil), trackingSince: "2026-10-21") == "No uses recorded yet")
        #expect(caption(.init(count: 0, lastUsed: nil, since: nil), trackingSince: nil) == "No uses recorded yet")
    }

    @Test func aUsedRuleSaysHowOftenAndWhenLast() {
        #expect(caption(.init(count: 1, lastUsed: "2026-10-21", since: nil)) == "Used in 1 dictation · last used today")
        #expect(caption(.init(count: 3, lastUsed: "2026-10-20", since: "2026-10-01")) == "Used in 3 dictations · last used yesterday")
        #expect(caption(.init(count: 14, lastUsed: "2026-10-19", since: nil)) == "Used in 14 dictations · last used Oct 19")
    }

    @Test func anUnreadableDateFallsBackToTheCount() {
        #expect(caption(.init(count: 2, lastUsed: "garbage", since: "garbage")) == "Used in 2 dictations")
        #expect(caption(.init(count: 0, lastUsed: nil, since: "garbage")) == "No uses recorded since Aug 1")
    }

    // MARK: Health

    private static let piRule = ReplacementRule(heard: "p[iy]e?", replace: "pi<CR>", isRegex: true, origin: .global)

    private static func effect(
        _ rule: ReplacementRule = piRule, changed: Bool = true, insideWord: Bool = false,
        returnOmitted: Bool = false, owns: Bool = false
    ) -> ReplacementEffect {
        ReplacementEffect(rule: rule, changedText: changed, insideWord: insideWord, returnOmitted: returnOmitted, ownsWholeDictation: owns)
    }

    private static let key = ReplacementUsage.key(for: piRule)!

    @Test func onlyMeaningfulEffectsCountAsUses() {
        let usage = ReplacementUsage()
            .recording(effects: [Self.effect(changed: false)], on: "2026-10-20")
            .recording(effects: [Self.effect(changed: false, owns: true)], on: "2026-10-21")
        #expect(usage.rules[Self.key]?.count == 1)
        #expect(usage.rules[Self.key]?.lastUsed == "2026-10-21")
    }

    @Test func aDroppedReturnIsRecordedEvenWhenTheWordsStayTheSame() {
        let usage = ReplacementUsage().recording(effects: [Self.effect(changed: false, returnOmitted: true)], on: "2026-10-20")
        #expect(usage.rules[Self.key]?.count == 0)
        #expect(usage.rules[Self.key]?.health?.returnOmitted == 1)
    }

    @Test func eachDictationCountsItsProblemsOnceWhateverTheMatchCount() {
        let usage = ReplacementUsage()
            .recording(effects: [Self.effect(insideWord: true, returnOmitted: true)], on: "2026-10-20")
            .recording(effects: [Self.effect(insideWord: true)], on: "2026-10-21")
        let health = usage.rules[Self.key]?.health
        #expect(health?.insideWord == 2)
        #expect(health?.returnOmitted == 1)
        #expect(usage.rules[Self.key]?.count == 2)
    }

    @Test func editingTheRuleStartsItsHealthOverAndKeepsItsUses() {
        let edited = ReplacementRule(heard: "p[iy]e?", replace: "pi", isRegex: true, origin: .global)
        let usage = ReplacementUsage()
            .recording(effects: [Self.effect(insideWord: true)], on: "2026-10-20")
            .recording(effects: [Self.effect(edited)], on: "2026-10-22")
        let entry = usage.rules[Self.key]
        #expect(entry?.count == 2)
        #expect(entry?.health?.insideWord == 0)
        #expect(entry?.health?.editedOn == "2026-10-22")
    }

    @Test func healthIsShownOnlyForTheRuleAsItIsNow() {
        let usage = ReplacementUsage().recording(effects: [Self.effect(insideWord: true, returnOmitted: true)], on: "2026-10-20")
        let entry = usage.rules[Self.key]
        let current = ReplacementsSet.Rule(heard: "p[iy]e?", replace: "pi<CR>", regex: true)
        #expect(ReplacementUsageCaption.health(for: entry, rule: current)
            == ["Changed text inside other words in 1 dictation", "Did not press Return in 1 dictation, because it matched mid-sentence"])
        var repaired = current
        repaired.wholeDictation = true
        #expect(ReplacementUsageCaption.health(for: entry, rule: repaired).isEmpty)
    }

    @Test func problemsAfterAnEditSayWhenTheyStarted() {
        let edited = ReplacementRule(heard: "p[iy]e?", replace: "pi!", isRegex: true, origin: .global)
        let usage = ReplacementUsage()
            .recording(effects: [Self.effect()], on: "2026-10-20")
            .recording(effects: [Self.effect(edited, insideWord: true)], on: "2026-10-22")
        let rule = ReplacementsSet.Rule(heard: "p[iy]e?", replace: "pi!", regex: true)
        #expect(ReplacementUsageCaption.health(for: usage.rules[Self.key], rule: rule)
            == ["Since you edited it: changed text inside other words in 1 dictation"])
    }
}
