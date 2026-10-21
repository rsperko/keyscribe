import Foundation
import Testing
@testable import KeyScribeKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func item(_ line: Int, daysAgo: Double, mode: String = "Notes", engine: String? = "Parakeet Ultra") -> HistorySnapshot.Item {
    var entry = HistoryEntry(
        timestamp: now.addingTimeInterval(-daysAgo * 86_400), modeName: mode, heard: "words \(line)",
        result: "", outcome: .inserted, cloudInvolved: false, redaction: false, contextCategories: [])
    entry.engine = engine
    return .init(reference: .init(dayFile: "d.jsonl", line: line), entry: entry)
}

struct HistorySearchScopeTests {
    @Test func limitsToThePeriod() {
        let items = [item(0, daysAgo: 40), item(1, daysAgo: 3)]
        let scope = HistorySearchScope(period: .days(30), model: .all)
        #expect(scope.matching(items, now: now).map(\.reference.line) == [1])
        #expect(HistorySearchScope(period: .all, model: .all).matching(items, now: now).count == 2)
    }

    @Test func includesEveryRecordedMode() {
        let items = [item(0, daysAgo: 1), item(1, daysAgo: 1, mode: "Code")]
        let scope = HistorySearchScope(period: .all, model: .all)
        #expect(scope.matching(items, now: now).map(\.reference.line) == [0, 1])
    }

    @Test func aModelFilterLeavesOutDictationsWithNoRecordedModelAndCountsThem() {
        let items = [item(0, daysAgo: 1, engine: nil), item(1, daysAgo: 1), item(2, daysAgo: 1, engine: "Whisper")]
        let scope = HistorySearchScope(period: .all, model: .named("Parakeet Ultra"))
        #expect(scope.matching(items, now: now).map(\.reference.line) == [1])
        #expect(scope.withoutRecordedModel(items, now: now) == 1)
        #expect(HistorySearchScope(period: .all, model: .all).withoutRecordedModel(items, now: now) == 0)
    }

    @Test func offersRecordedModelsMostRecentFirst() {
        let items = [item(0, daysAgo: 5, engine: "Whisper"), item(1, daysAgo: 1), item(2, daysAgo: 9), item(3, daysAgo: 2, engine: nil)]
        #expect(HistorySearchScope.recordedModels(in: items) == ["Parakeet Ultra", "Whisper"])
    }

    @Test func defaultsToTheMostRecentModelAcrossModesWithinThePeriod() {
        let items = [item(0, daysAgo: 1, mode: "Code", engine: "Whisper"), item(1, daysAgo: 3), item(2, daysAgo: 50, engine: "Apple")]
        let scope = HistorySearchScope.defaults(in: items, now: now)
        #expect(scope == HistorySearchScope(period: .days(30), model: .named("Whisper")))
        let empty = HistorySearchScope.defaults(in: [], now: now)
        #expect(empty.model == .all)
    }
}

struct AliasDiscoveryHandledTodayTests {
    @Test func setsAsideFindingsTodaysReplacementsOrRecoveryAlreadyFix() {
        let texts = ["Ugabyte and Yuga Bite and UGBte"]
        let findings = AliasDiscovery.find(target: "Yugabyte", in: texts)
        let stages: [any PipelineStage] = [
            ReplacementsStage(rules: [ReplacementRule(heard: "Yuga Bite", replace: "Yugabyte", isRegex: false)]),
            FuzzyStage(terms: ["Yugabyte"]),
        ]
        let split = AliasDiscovery.separatingHandled(findings, in: texts, target: "Yugabyte", stages: { _ in stages })
        #expect(Set(split.handled.map(\.phrase)) == ["Ugabyte", "Yuga Bite"])
        #expect(split.open.map(\.phrase) == ["UGBte"])
    }

    @Test func aPhraseIsHandledOnlyWhereItIsFixedInsideTheDictation() {
        let texts = ["The UGBte cluster is down."]
        let findings = AliasDiscovery.find(target: "Yugabyte", in: texts)
        let stages: [any PipelineStage] = [
            ReplacementsStage(rules: [ReplacementRule(heard: "^UGBte$", replace: "Yugabyte", isRegex: true)]),
        ]
        let split = AliasDiscovery.separatingHandled(findings, in: texts, target: "Yugabyte", stages: { _ in stages })
        #expect(split.open.map(\.phrase) == ["UGBte"])
        #expect(split.handled.isEmpty)
    }

    @Test func aPhraseReplacedWithSomethingElseIsNotCreditedWithAnotherPhrasesFix() {
        let texts = ["The UGBte and Yuga Bite clusters are down."]
        let findings = AliasDiscovery.find(target: "Yugabyte", in: texts)
        let stages: [any PipelineStage] = [
            ReplacementsStage(rules: [
                ReplacementRule(heard: "UGBte", replace: "Uganda", isRegex: false),
                ReplacementRule(heard: "Yuga Bite", replace: "Yugabyte", isRegex: false),
            ]),
        ]
        let split = AliasDiscovery.separatingHandled(findings, in: texts, target: "Yugabyte", stages: { _ in stages })
        #expect(split.open.map(\.phrase) == ["UGBte"])
        #expect(split.handled.map(\.phrase) == ["Yuga Bite"])
    }

    @Test func aPhraseFixedInOneDictationButNotAnotherStaysOpen() {
        let texts = ["UGBte", "The UGBte cluster is down."]
        let findings = AliasDiscovery.find(target: "Yugabyte", in: texts)
        let stages: [any PipelineStage] = [
            ReplacementsStage(rules: [ReplacementRule(heard: "^UGBte$", replace: "Yugabyte", isRegex: true)]),
        ]
        let split = AliasDiscovery.separatingHandled(findings, in: texts, target: "Yugabyte", stages: { _ in stages })
        #expect(split.open.map(\.phrase) == ["UGBte"])
    }
}
