import Foundation
import Testing
@testable import KeyScribeKit

struct VocabularyConfigTests {
    @Test func decodesDictionaryToml() throws {
        let toml = """
        schema_version = 1
        words = ["KeyScribe", "Parakeet", "Anthropic"]
        """
        let d = try DictionaryStore.decode(from: toml)
        #expect(d.words == ["KeyScribe", "Parakeet", "Anthropic"])
    }

    @Test func decodesReplacementsToml() throws {
        let toml = """
        schema_version = 1
        [[rules]]
        heard = "teh"
        replace = "the"
        regex = false
        """
        let r = try ReplacementsStore.decode(from: toml)
        #expect(r.rules.count == 1)
        #expect(r.toRules() == [ReplacementRule(heard: "teh", replace: "the", isRegex: false)])
    }

    // A single-quoted TOML literal string keeps `\n` as backslash+n, so the regex expansion — not TOML's
    // own basic-string decoding — is what produces the newline.
    @Test func regexEscapeExpansionRunsThroughTheTomlLiteralStringPath() throws {
        let toml = """
        schema_version = 1
        [[rules]]
        heard = 'insert code fence'
        replace = '```\\n'
        regex = true
        """
        let rules = try ReplacementsStore.decode(from: toml).toRules()
        #expect(rules[0].replace == #"```\n"#)
        var ctx = PipelineContext(text: "insert code fence")
        ReplacementsStage(rules: rules).apply(&ctx)
        #expect(ctx.text == "```\n")
        #expect(ctx.bareReplacement?.text == "```\n")
    }

    @Test func literalRuleThroughTomlLeavesEscapeUninterpreted() throws {
        let toml = """
        schema_version = 1
        [[rules]]
        heard = 'fence'
        replace = '```\\n'
        regex = false
        """
        let rules = try ReplacementsStore.decode(from: toml).toRules()
        var ctx = PipelineContext(text: "fence")
        ReplacementsStage(rules: rules).apply(&ctx)
        #expect(ctx.text == #"```\n"#)
    }

    // TOMLKit encodes a backslash value as a literal string, so the write→load round-trip preserves the
    // `\n` the regex expansion needs.
    @Test func settingsWriteRoundTripPreservesBackslashEscape() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-replacements-escape-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = ReplacementsSet(rules: [.init(heard: "insert code fence", replace: #"```\n"#, regex: true)])
        try ReplacementsStore.write(set, to: dir)
        guard case let .loaded(reloaded) = ReplacementsStore.load(supportDir: dir) else {
            Issue.record("expected .loaded"); return
        }
        #expect(reloaded.rules[0].replace == #"```\n"#)
        var ctx = PipelineContext(text: "insert code fence")
        ReplacementsStage(rules: reloaded.toRules()).apply(&ctx)
        #expect(ctx.bareReplacement?.text == "```\n")
    }

    @Test func roundTripsExactMultilineReplacement() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-replacements-multiline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = "  leading spaces\n\ttab-indented line\ntrailing spaces here   \n\nblank line above\n\"double\" 'single' \\ backslash and a visible \\n here\n"
        let set = ReplacementsSet(rules: [.init(heard: "expand", replace: body, regex: false)])
        try ReplacementsStore.write(set, to: dir)
        guard case let .loaded(reloaded) = ReplacementsStore.load(supportDir: dir) else {
            Issue.record("expected .loaded"); return
        }
        #expect(reloaded.rules[0].replace == body)
    }

    @Test func oversizedRuleStillLoads() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-replacements-oversized-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let huge = String(repeating: "a", count: ReplacementAuthoring.maxCharacters + 100)
        let set = ReplacementsSet(rules: [
            .init(heard: "small", replace: "ok", regex: false),
            .init(heard: "huge", replace: huge, regex: false),
        ])
        try ReplacementsStore.write(set, to: dir)
        guard case let .loaded(reloaded) = ReplacementsStore.load(supportDir: dir) else {
            Issue.record("expected .loaded, not a whole-file failure"); return
        }
        #expect(reloaded.rules.count == 2)
        #expect(reloaded.rules[1].replace == huge)
    }

    @Test func missingSchemaVersionThrows() {
        #expect(throws: ConfigError.missingSchemaVersion) {
            try DictionaryStore.decode(from: "words = []")
        }
    }

    @Test func newerSchemaVersionThrows() {
        #expect(throws: ConfigError.newerSchemaVersion(found: 99, supported: 1)) {
            try DictionaryStore.decode(from: "schema_version = 99\nwords = []")
        }
    }

    @Test func replacementsLoadReportsAbsentLoadedAndFailed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-replacements-load-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ReplacementsStore.load(supportDir: dir) == .absent)

        let set = ReplacementsSet(rules: [.init(heard: "teh", replace: "the", regex: false)])
        try ReplacementsStore.write(set, to: dir)
        #expect(ReplacementsStore.load(supportDir: dir) == .loaded(set))

        // A `[[rules]` typo must surface as .failed, not silently disable every replacement.
        try "schema_version = 1\n[[rules]\nheard = \"a\"".write(
            to: dir.appendingPathComponent(ReplacementsStore.fileName), atomically: true, encoding: .utf8)
        guard case .failed = ReplacementsStore.load(supportDir: dir) else {
            Issue.record("expected .failed for malformed replacements.toml")
            return
        }
        #expect(ReplacementsStore.loadOrDefault(supportDir: dir).rules.isEmpty)
    }

    @Test func dictionaryLoadReportsNewerSchemaAsFailed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-dictionary-load-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        #expect(DictionaryStore.load(supportDir: dir) == .absent)
        try "schema_version = 99\nwords = []".write(
            to: dir.appendingPathComponent(DictionaryStore.fileName), atomically: true, encoding: .utf8)
        #expect(DictionaryStore.load(supportDir: dir) == .failed(.newerSchemaVersion(found: 99, supported: 1)))
        #expect(DictionaryStore.loadOrDefault(supportDir: dir).words.isEmpty)
    }

    @Test func mergeWordsIncludesGlobal() {
        #expect(VocabularyMerge.words(global: ["a", "b"], local: ["c"], includeGlobal: true) == ["a", "b", "c"])
    }

    @Test func mergeWordsExcludesGlobal() {
        #expect(VocabularyMerge.words(global: ["a", "b"], local: ["c"], includeGlobal: false) == ["c"])
    }

    @Test func mergeWordsDedupesPreservingOrder() {
        #expect(VocabularyMerge.words(global: ["a", "b"], local: ["b", "c"], includeGlobal: true) == ["a", "b", "c"])
    }

    @Test func mergeWordsDedupesCaseInsensitively() {
        #expect(VocabularyMerge.words(global: ["kubernetes"], local: ["Kubernetes"], includeGlobal: true)
            == ["Kubernetes"])
    }

    @Test func mergeWordsDedupesLocalWordsWhenGlobalWordsAreExcluded() {
        #expect(VocabularyMerge.words(global: [], local: ["Kubernetes", "kubernetes"], includeGlobal: false)
            == ["Kubernetes"])
    }

    @Test func mergeWordsPreservesGlobalOrderWhenLocalCasingOverrides() {
        #expect(VocabularyMerge.words(
            global: ["alpha", "github", "omega"],
            local: ["GitHub", "beta"],
            includeGlobal: true) == ["alpha", "GitHub", "omega", "beta"])
    }

    @Test func mergeWordsEmptyWhenAllInputsEmpty() {
        #expect(VocabularyMerge.words(global: [], local: [], includeGlobal: true) == [])
        #expect(VocabularyMerge.words(global: [], local: [], includeGlobal: false) == [])
    }

    @Test func mergeWordsEmptyWhenGlobalExcludedAndLocalEmpty() {
        #expect(VocabularyMerge.words(global: ["a", "b"], local: [], includeGlobal: false) == [])
    }

    @Test func mergeRulesLocalRunBeforeGlobal() {
        let g = [ReplacementRule(heard: "a", replace: "1", isRegex: false)]
        let l = [ReplacementRule(heard: "b", replace: "2", isRegex: false)]
        #expect(VocabularyMerge.rules(global: g, local: l, includeGlobal: true) == l + g)
        #expect(VocabularyMerge.rules(global: g, local: l, includeGlobal: false) == l)
    }

    @Test func mergeRulesLocalOverridesGlobalSameHeard() {
        let g = [ReplacementRule(heard: "k8s", replace: "Kubernetes", isRegex: false)]
        let l = [ReplacementRule(heard: "k8s", replace: "k8s cluster", isRegex: false)]
        #expect(VocabularyMerge.rules(global: g, local: l, includeGlobal: true) == l)
    }

    @Test func mergeRulesLocalOverridesGlobalCaseInsensitivelyForLiterals() {
        let g = [ReplacementRule(heard: "K8S", replace: "Kubernetes", isRegex: false)]
        let l = [ReplacementRule(heard: "k8s", replace: "k8s cluster", isRegex: false)]
        #expect(VocabularyMerge.rules(global: g, local: l, includeGlobal: true) == l)
    }

    @Test func mergeRulesOverrideKeepsUnrelatedGlobalsInOrder() {
        let g = [
            ReplacementRule(heard: "a", replace: "1", isRegex: false),
            ReplacementRule(heard: "b", replace: "2", isRegex: false),
        ]
        let l = [ReplacementRule(heard: "B", replace: "two", isRegex: false)]
        #expect(VocabularyMerge.rules(global: g, local: l, includeGlobal: true)
            == [ReplacementRule(heard: "B", replace: "two", isRegex: false),
                ReplacementRule(heard: "a", replace: "1", isRegex: false)])
    }

    @Test func mergeRulesLiteralAndRegexSameHeardAreDistinctKeys() {
        let g = [ReplacementRule(heard: "foo", replace: "global", isRegex: false)]
        let l = [ReplacementRule(heard: "foo", replace: "local", isRegex: true)]
        #expect(VocabularyMerge.rules(global: g, local: l, includeGlobal: true) == l + g)
    }

    @Test func mergeRulesRegexOverrideIsCaseSensitive() {
        let g = [ReplacementRule(heard: "Foo(.*)", replace: "global", isRegex: true)]
        let l = [ReplacementRule(heard: "foo(.*)", replace: "local", isRegex: true)]
        #expect(VocabularyMerge.rules(global: g, local: l, includeGlobal: true) == l + g)
    }

    @Test func replacingRulePreservesItsPosition() {
        let original = ReplacementsSet.Rule(heard: "teh", replace: "the", regex: false)
        let updated = ReplacementsSet.Rule(heard: "teh", replace: "The", regex: false)
        let other = ReplacementsSet.Rule(heard: "wont", replace: "won't", regex: false)

        let result = ReplacementsSet(rules: [original, other]).replacing(original, with: updated)

        #expect(result.rules == [updated, other])
    }

    @Test func replacingRuleDoesNotCreateAConflictingIdentity() {
        let first = ReplacementsSet.Rule(heard: "teh", replace: "the", regex: false)
        let second = ReplacementsSet.Rule(heard: "wont", replace: "won't", regex: false)
        let conflicting = ReplacementsSet.Rule(heard: "WONT", replace: "will not", regex: false)

        let result = ReplacementsSet(rules: [first, second]).replacing(first, with: conflicting)

        #expect(result.rules == [first, second])
    }

    @Test func reorderingKnownRulesPreservesRulesAddedElsewhere() {
        let first = ReplacementsSet.Rule(heard: "first", replace: "1", regex: false)
        let second = ReplacementsSet.Rule(heard: "second", replace: "2", regex: false)
        let added = ReplacementsSet.Rule(heard: "added", replace: "3", regex: false)

        let result = ReplacementsSet(rules: [first, second, added]).reordering([second, first])

        #expect(result.rules == [second, first, added])
    }

    @Test func reorderingIgnoresAVisibleRuleChangedElsewhere() {
        let first = ReplacementsSet.Rule(heard: "first", replace: "1", regex: false)
        let second = ReplacementsSet.Rule(heard: "second", replace: "2", regex: false)
        let changed = ReplacementsSet.Rule(heard: "first", replace: "one", regex: false)

        let result = ReplacementsSet(rules: [changed, second]).reordering([second, first])

        #expect(result.rules == [changed, second])
    }

    @Test func reorderingPreservesDuplicateRulesAddedOutsideTheApp() {
        let first = ReplacementsSet.Rule(heard: "first", replace: "1", regex: false)
        let second = ReplacementsSet.Rule(heard: "second", replace: "2", regex: false)

        let result = ReplacementsSet(rules: [first, second, first]).reordering([second, first])

        #expect(result.rules == [second, first, first])
    }

    @Test func removingDictionaryWordMatchesCaseInsensitively() {
        let set = DictionarySet(words: ["KeyScribe", "Parakeet"])
        #expect(set.removing(word: "keyscribe").words == ["Parakeet"])
    }

    @Test func addingDictionaryWordRecasesAnExistingWord() {
        let set = DictionarySet(words: ["github"]).adding(word: "GitHub")
        #expect(set.words == ["GitHub"])
    }
}
