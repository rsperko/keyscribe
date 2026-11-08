import Testing
@testable import KeyScribeKit

struct SharedVocabularyConflictTests {
    private func rule(_ heard: String, _ replace: String, alone: Bool = false) -> ReplacementsSet.Rule {
        ReplacementsSet.Rule(heard: heard, replace: replace, regex: false, wholeDictation: alone)
    }

    private func mode(uses: [String], ownWords: [String] = [], ownRules: [ReplacementsSet.Rule] = []) -> Mode {
        var m = Mode(id: "code", name: "Code")
        m.sharedVocabularies = uses
        m.dictionary.words = ownWords
        m.replacements.rules = ownRules
        return m
    }

    private let programming = SharedVocabulary(
        id: "programming", name: "Programming", words: ["Kubernetes"], rules: [.init(heard: "pain", replace: "pane", regex: false)])

    @Test func twoVocabulariesReplacingAPhraseDifferentlyCompeteWithEveryOption() {
        let medical = SharedVocabulary(id: "medical", name: "Medical", rules: [rule("Pain", "pain.")])
        let docs = SharedVocabulary(id: "docs", name: "Docs", rules: [rule("pain", "pane")])
        let found = SharedVocabularyConflicts.competitions(
            in: mode(uses: ["programming", "medical", "docs"]), shared: [programming, medical, docs])
        #expect(found == [.init(key: "l:pain", phrase: "pain", options: [
            .init(entry: .rule(rule("pain", "pane")), sources: ["Programming", "Docs"]),
            .init(entry: .rule(rule("Pain", "pain.")), sources: ["Medical"]),
        ])])
    }

    @Test func theSameOutputWithADifferentScopeIsADistinctOption() {
        let medical = SharedVocabulary(id: "medical", name: "Medical", rules: [rule("pain", "pane", alone: true)])
        let found = SharedVocabularyConflicts.competitions(in: mode(uses: ["programming", "medical"]), shared: [programming, medical])
        #expect(found.first?.options.map(\.entry) == [.rule(rule("pain", "pane")), .rule(rule("pain", "pane", alone: true))])
    }

    @Test func differentSpellingsCompeteAndTheModesOwnEntriesDecide() {
        let medical = SharedVocabulary(id: "medical", name: "Medical", words: ["kubernetes"], rules: [rule("pain", "x")])
        let found = SharedVocabularyConflicts.competitions(in: mode(uses: ["programming", "medical"]), shared: [programming, medical])
        #expect(found.map(\.key) == ["w:kubernetes", "l:pain"])
        #expect(found.first?.spelling == true)
        #expect(SharedVocabularyConflicts.competitions(
            in: mode(uses: ["programming", "medical"], ownWords: ["KUBERNETES"], ownRules: [rule("Pain", "y")]),
            shared: [programming, medical]).isEmpty)
    }

    @Test func identicalEntriesAreNoCompetition() {
        let copy = SharedVocabulary(id: "copy", name: "Copy", words: ["Kubernetes"], rules: [rule("PAIN", "pane")])
        #expect(SharedVocabularyConflicts.competitions(in: mode(uses: ["programming", "copy"]), shared: [programming, copy]).isEmpty)
    }

    @Test func attachingDescribesWhatChangesFromGlobalOnlyWhereNothingElseDecides() {
        let global = ReplacementsSet(rules: [rule("Pain", "panel")])
        #expect(SharedVocabularyConflicts.globalChanges(
            attaching: programming, to: mode(uses: []), shared: [programming], global: global, globalWords: ["KUBERNETES"])
            == [.init(current: .word("KUBERNETES"), proposed: .word("Kubernetes")),
                .init(current: .rule(rule("Pain", "panel")), proposed: .rule(rule("pain", "pane")))])
        #expect(SharedVocabularyConflicts.globalChanges(
            attaching: programming, to: mode(uses: [], ownWords: ["kubernetes"], ownRules: [rule("pain", "p")]),
            shared: [programming], global: global, globalWords: ["KUBERNETES"]).isEmpty)
        var noGlobal = mode(uses: [])
        noGlobal.dictionary.includeGlobal = false
        noGlobal.replacements.includeGlobal = false
        #expect(SharedVocabularyConflicts.globalChanges(
            attaching: programming, to: noGlobal, shared: [programming], global: global, globalWords: ["KUBERNETES"]).isEmpty)
    }

    @Test func onlyDisagreementsAChangeCreatesAreIntroduced() {
        let medical = SharedVocabulary(id: "medical", name: "Medical", words: ["kubernetes"])
        let code = mode(uses: ["programming", "medical"])
        var changed = programming
        changed.rules.append(rule("kube", "k8s"))
        let alsoMedical = SharedVocabulary(id: "medical", name: "Medical", words: ["kubernetes"], rules: [rule("kube", "kubectl")])
        let introduced = SharedVocabularyConflicts.introduced(
            modesBefore: [code], sharedBefore: [programming, medical], modesAfter: [code], sharedAfter: [changed, alsoMedical])
        #expect(introduced.map(\.competition.key) == ["l:kube"])
        #expect(introduced.first?.modeName == "Code")
        #expect(SharedVocabularyConflicts.introduced(
            modesBefore: [code], sharedBefore: [programming, medical], modesAfter: [code], sharedAfter: [programming, medical]).isEmpty)
    }
}
