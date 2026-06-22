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

    @Test func mergeWordsIncludesGlobal() {
        #expect(VocabularyMerge.words(global: ["a", "b"], local: ["c"], includeGlobal: true) == ["a", "b", "c"])
    }

    @Test func mergeWordsExcludesGlobal() {
        #expect(VocabularyMerge.words(global: ["a", "b"], local: ["c"], includeGlobal: false) == ["c"])
    }

    @Test func mergeWordsDedupesPreservingOrder() {
        #expect(VocabularyMerge.words(global: ["a", "b"], local: ["b", "c"], includeGlobal: true) == ["a", "b", "c"])
    }

    @Test func mergeWordsEmptyWhenAllInputsEmpty() {
        #expect(VocabularyMerge.words(global: [], local: [], includeGlobal: true) == [])
        #expect(VocabularyMerge.words(global: [], local: [], includeGlobal: false) == [])
    }

    @Test func mergeWordsEmptyWhenGlobalExcludedAndLocalEmpty() {
        #expect(VocabularyMerge.words(global: ["a", "b"], local: [], includeGlobal: false) == [])
    }

    @Test func mergeRulesGlobalRunBeforeLocal() {
        let g = [ReplacementRule(heard: "a", replace: "1", isRegex: false)]
        let l = [ReplacementRule(heard: "b", replace: "2", isRegex: false)]
        #expect(VocabularyMerge.rules(global: g, local: l, includeGlobal: true) == g + l)
        #expect(VocabularyMerge.rules(global: g, local: l, includeGlobal: false) == l)
    }

    @Test func removingDictionaryWordMatchesCaseInsensitively() {
        let set = DictionarySet(words: ["KeyScribe", "Parakeet"])
        #expect(set.removing(word: "keyscribe").words == ["Parakeet"])
    }
}
