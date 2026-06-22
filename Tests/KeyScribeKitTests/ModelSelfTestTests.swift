import Testing
@testable import KeyScribeKit

struct ModelSelfTestTests {
    private let expected = ["quick", "brown", "fox"]

    @Test func passesWhenEnoughWordsPresent() {
        #expect(ModelSelfTest.passes(
            transcript: "The quick brown fox jumps over the lazy dog.",
            expectedWords: expected, minMatches: 2))
    }

    @Test func passesAtThresholdWithOneWordDropped() {
        // 2 of 3 distinctive words is enough — tolerates per-model wording differences.
        #expect(ModelSelfTest.passes(
            transcript: "the quick brown ox", expectedWords: expected, minMatches: 2))
    }

    @Test func failsWhenOnlyOneWordMatches() {
        #expect(!ModelSelfTest.passes(
            transcript: "a quick note", expectedWords: expected, minMatches: 2))
    }

    @Test func failsOnEmptyOrGarbageOutput() {
        #expect(!ModelSelfTest.passes(transcript: "", expectedWords: expected, minMatches: 2))
        #expect(!ModelSelfTest.passes(transcript: "blah blah blah", expectedWords: expected, minMatches: 2))
    }

    @Test func normalizationIgnoresCaseAndPunctuation() {
        #expect(ModelSelfTest.normalize("The QUICK, brown!! fox?") == "the quick brown fox")
    }
}
