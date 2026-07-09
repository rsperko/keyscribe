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

    @Test func falseFireWhenTermInHypButNotReference() {
        // "GitHub" surfaced in the transcript but the sentence was about getting up early → false fire.
        let n = BenchmarkScoring.termFalseFires(
            terms: ["GitHub"], reference: "I need to get up early", hypothesis: "I need to GitHub early")
        #expect(n == 1)
    }

    @Test func noFalseFireWhenTermLegitimatelySpoken() {
        // The term is in the reference, so its presence in the hypothesis is correct, not a false fire.
        let n = BenchmarkScoring.termFalseFires(
            terms: ["GitHub"], reference: "I pushed to GitHub", hypothesis: "I pushed to GitHub")
        #expect(n == 0)
    }

    @Test func noFalseFireWhenTermAbsentFromBoth() {
        let n = BenchmarkScoring.termFalseFires(
            terms: ["GitHub"], reference: "I need to get up early", hypothesis: "I need to get up early")
        #expect(n == 0)
    }

    @Test func falseFiresCountsEachOffendingTerm() {
        let n = BenchmarkScoring.termFalseFires(
            terms: ["GitHub", "Kubernetes", "TypeScript"],
            reference: "our local communities use that type of script",
            hypothesis: "our local Kubernetes use that TypeScript")
        #expect(n == 2)
    }

    @Test func falseFiresIsCaseInsensitiveAndIgnoresBlankTerms() {
        let n = BenchmarkScoring.termFalseFires(
            terms: ["GitHub", "  "], reference: "get up now", hypothesis: "github now")
        #expect(n == 1)
    }
}
