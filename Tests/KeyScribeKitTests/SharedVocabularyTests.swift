import Foundation
import Testing
@testable import KeyScribeKit

struct SharedVocabularyTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-shared-\(UUID().uuidString)", isDirectory: true)
    }

    private let programming = SharedVocabulary(
        id: "programming", name: "Programming", words: ["Kubernetes"],
        rules: [.init(heard: "pain", replace: "pane", regex: false)])

    @Test func aSharedVocabularyRoundTripsThroughItsOwnFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SharedVocabularyStore.write(programming, to: dir)
        let loaded = SharedVocabularyStore.load(in: dir)
        #expect(loaded.vocabularies == [programming])
        #expect(loaded.failures.isEmpty)
        let toml = try String(contentsOf: dir.appendingPathComponent("programming.toml"), encoding: .utf8)
        #expect(toml.contains("schema_version = 1"))
        #expect(try SharedVocabularyStore.decode(from: toml, id: "programming").name == "Programming")
        #expect(SharedVocabularyStore.unknownKeys(in: toml).isEmpty)
    }

    @Test func anUnreadableSharedVocabularyIsAFailureNotAnEmptyOne() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "name = [".write(to: dir.appendingPathComponent("broken.toml"), atomically: true, encoding: .utf8)
        let loaded = SharedVocabularyStore.load(in: dir)
        #expect(loaded.vocabularies.isEmpty)
        #expect(loaded.failures.map(\.id) == ["broken"])
    }

    @Test func aMissingFolderMeansNoSharedVocabularies() {
        #expect(SharedVocabularyStore.load(in: tempDir()).vocabularies.isEmpty)
    }

    @Test func aKeyNothingReadsIsReported() {
        let toml = "schema_version = 1\nname = \"P\"\nwordz = [\"a\"]\n"
        #expect(SharedVocabularyStore.unknownKeys(in: toml).map(\.path) == ["wordz"])
    }

    @Test func anIdIsMadeFromTheNameAndNeverReusesOne() {
        #expect(SharedVocabularyStore.newId(for: "Programming & Docs", existing: []) == "programming-docs")
        #expect(SharedVocabularyStore.newId(for: "Programming", existing: ["programming"]) == "programming-2")
        #expect(SharedVocabularyStore.newId(for: "!!!", existing: []) == "vocabulary")
    }

    @Test func aModeListsTheSharedVocabulariesItUsesAndWritesNothingWhenItUsesNone() throws {
        var mode = Mode(id: "code", name: "Code")
        #expect(!(try ModeStore.encode(mode)).contains("shared_vocabularies"))
        mode.sharedVocabularies = ["programming"]
        let decoded = try ModeStore.decode(from: try ModeStore.encode(mode), id: "code")
        #expect(decoded.sharedVocabularies == ["programming"])
        #expect(ModeStore.unknownKeys(in: try ModeStore.encode(mode)).isEmpty)
    }

    @Test func plainDictationNeverUsesASharedVocabulary() {
        var direct = Mode.direct
        direct.sharedVocabularies = ["programming"]
        #expect(direct.systemNormalized().sharedVocabularies.isEmpty)
        var commands = Mode.voiceCommands
        commands.sharedVocabularies = ["programming"]
        #expect(commands.systemNormalized().sharedVocabularies == ["programming"])
    }

    @Test func modeWordsOverrideSharedWordsWhichOverrideGlobalOnes() {
        let words = VocabularyMerge.words(
            global: ["kubernetes", "Postgres"], shared: [["Kubernetes", "Redis"], ["redis", "Kafka"]],
            local: ["KAFKA"], includeGlobal: true)
        #expect(words == ["Kubernetes", "Postgres", "Redis", "KAFKA"])
        #expect(VocabularyMerge.words(global: ["Postgres"], shared: [["Redis"]], local: [], includeGlobal: false) == ["Redis"])
    }

    @Test func modeRulesOverrideSharedRulesWhichOverrideGlobalOnes() {
        let global = [ReplacementRule(heard: "pain", replace: "pain", isRegex: false), ReplacementRule(heard: "teh", replace: "the", isRegex: false)]
        let first = [ReplacementRule(heard: "pain", replace: "pane", isRegex: false), ReplacementRule(heard: "kube", replace: "k8s", isRegex: false)]
        let second = [ReplacementRule(heard: "PAIN", replace: "panel", isRegex: false)]
        let local = [ReplacementRule(heard: "kube", replace: "Kubernetes", isRegex: false)]
        let rules = VocabularyMerge.rules(global: global, shared: [first, second], local: local, includeGlobal: true)
        #expect(rules.map(\.replace) == ["Kubernetes", "pane", "the"])
        #expect(VocabularyMerge.rules(global: global, shared: [first], local: [], includeGlobal: false).map(\.replace) == ["pane", "k8s"])
    }

    @Test func aModeDictatesWithTheSharedVocabulariesItUses() {
        var code = Mode(id: "code", name: "Code")
        code.sharedVocabularies = ["programming", "gone"]
        let email = Mode(id: "email", name: "Email")
        let resolved = ResolvedConfig(
            modes: [code, email], dictionary: DictionarySet(words: ["Postgres"]), replacements: ReplacementsSet(),
            connections: ConnectionSet(), fragments: [:], shared: [programming])
        #expect(resolved.mergedDictionary(for: code) == ["Postgres", "Kubernetes"])
        #expect(resolved.mergedDictionary(for: email) == ["Postgres"])
        let payload = Pipeline(resolved.postSTTTextStages(for: code)).forward("a pain")
        #expect(payload.text == "a pane")
        #expect(payload.replacementEffects.first?.rule.origin == .shared("programming"))
        #expect(Pipeline(resolved.postSTTTextStages(for: email)).forward("a pain").text == "a pain")
    }

    @Test func aSharedRuleIsCountedUnderItsOwnVocabulary() {
        let rule = ReplacementRule(heard: "pain", replace: "pane", isRegex: false, origin: .shared("programming"))
        #expect(ReplacementUsage.key(for: rule) == "shared:programming|l|pain")
    }

    @Test func aNewVocabularyGetsTheFirstFreePlaceholderName() {
        #expect(SharedVocabularyStore.newName(among: []) == "New Vocabulary")
        let taken = [SharedVocabulary(id: "a", name: "new vocabulary"), SharedVocabulary(id: "b", name: "New Vocabulary 2")]
        #expect(SharedVocabularyStore.newName(among: taken) == "New Vocabulary 3")
    }

    @Test func aNameMustBeGivenAndTellableFromGlobalAndTheOthers() {
        let existing = [programming]
        #expect(SharedVocabularyStore.nameProblem("  ", among: existing) == "Enter a name.")
        #expect(SharedVocabularyStore.nameProblem("global", among: existing)
            == "\u{201C}Global\u{201D} is the vocabulary every mode can use. Choose another name.")
        #expect(SharedVocabularyStore.nameProblem(" programming ", among: existing)
            == "A shared vocabulary is already named \u{201C}Programming\u{201D}.")
        #expect(SharedVocabularyStore.nameProblem("Programming", among: existing, renaming: "programming") == nil)
        #expect(SharedVocabularyStore.nameProblem("Medical", among: existing) == nil)
    }

    @Test func aSharedRuleIsAConfiguredRuleSoItsUsesAreKept() {
        let keys = ReplacementUsage.configuredKeys(global: ReplacementsSet(), modes: [], shared: [programming])
        #expect(keys == ["shared:programming|l|pain"])
    }
}

struct IncludedVocabularyTests {
    private func rule(_ heard: String, _ replace: String) -> ReplacementsSet.Rule {
        ReplacementsSet.Rule(heard: heard, replace: replace, regex: false)
    }

    @Test func listsWhatAModeInheritsWithItsSourceAndOnlyTheEntryInEffect() {
        let programming = SharedVocabulary(
            id: "programming", name: "Programming", words: ["Kubernetes", "Rust"], rules: [rule("pain", "pane"), rule("kube", "k8s")])
        var mode = Mode(id: "code", name: "Code")
        mode.sharedVocabularies = ["programming"]
        mode.dictionary.words = ["rust"]
        mode.replacements.rules = [rule("Kube", "kubectl")]
        let included = VocabularyMerge.included(
            in: mode, globalWords: ["kubernetes", "Postgres"], global: ReplacementsSet(rules: [rule("pain", "panel"), rule("pg", "Postgres")]),
            shared: [programming])
        #expect(included.words == [.init(value: "Kubernetes", source: "programming"), .init(value: "Postgres", source: nil)])
        #expect(included.rules == [.init(value: rule("pain", "pane"), source: "programming"), .init(value: rule("pg", "Postgres"), source: nil)])
    }

    @Test func aModeThatLeavesOutGlobalInheritsOnlyShared() {
        var mode = Mode(id: "code", name: "Code")
        mode.dictionary.includeGlobal = false
        mode.replacements.includeGlobal = false
        let included = VocabularyMerge.included(
            in: mode, globalWords: ["Postgres"], global: ReplacementsSet(rules: [rule("pg", "Postgres")]), shared: [])
        #expect(included.words.isEmpty)
        #expect(included.rules.isEmpty)
    }
}
