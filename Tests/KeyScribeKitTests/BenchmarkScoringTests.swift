import Testing
@testable import KeyScribeKit

struct BenchmarkScoringTests {
    @Test func identicalIsZeroWER() {
        #expect(BenchmarkScoring.wer(reference: "the quick brown fox", hypothesis: "the quick brown fox") == 0)
    }

    @Test func oneSubstitutionOfFiveIsPointTwo() {
        let w = BenchmarkScoring.wer(reference: "one two three four five", hypothesis: "one two THREEX four five")
        #expect(abs(w - 0.2) < 1e-9)
    }

    @Test func werIgnoresCaseAndPunctuation() {
        #expect(BenchmarkScoring.wer(reference: "Hello, world!", hypothesis: "hello world") == 0)
    }

    @Test func deletionAndInsertionCount() {
        // ref 3 words; hyp drops one and adds one elsewhere → 2 edits / 3
        let w = BenchmarkScoring.wer(reference: "alpha beta gamma", hypothesis: "alpha gamma delta")
        #expect(abs(w - (2.0 / 3.0)) < 1e-9)
    }

    @Test func emptyReferenceWithOutputIsFullError() {
        #expect(BenchmarkScoring.wer(reference: "", hypothesis: "stuff") == 1)
        #expect(BenchmarkScoring.wer(reference: "", hypothesis: "") == 0)
    }

    @Test func termRecallCaseInsensitivePresence() {
        #expect(BenchmarkScoring.termRecall(terms: ["KeyScribe"], in: "I use keyscribe daily") == 1)
        #expect(BenchmarkScoring.termRecall(terms: ["KeyScribe"], in: "I use Stan word daily") == 0)
    }

    @Test func termRecallIsFractionOfTermsHit() {
        let r = BenchmarkScoring.termRecall(terms: ["KeyScribe", "Kubernetes"], in: "KeyScribe runs locally")
        #expect(abs(r - 0.5) < 1e-9)
    }
}
