import Testing
@testable import KeyScribeKit

private func fix(_ s: String, _ terms: [String]) -> String { FuzzyCorrector.apply(s, terms: terms) }

struct FuzzyCorrectorTests {
    @Test func snapsSplitProperNoun() {
        #expect(fix("we use charge bee for billing", ["ChargeBee"]) == "we use ChargeBee for billing")
    }

    @Test func fixesCasingAndSpacing() {
        #expect(fix("deploy to kubernetes today", ["Kubernetes"]) == "deploy to Kubernetes today")
        #expect(fix("the chargebee invoice", ["ChargeBee"]) == "the ChargeBee invoice")
    }

    @Test func correctsSmallMisspelling() {
        #expect(fix("install postgress now", ["Postgres"]) == "install Postgres now")
    }

    @Test func leavesUnrelatedWordsAlone() {
        #expect(fix("the cat sat on the mat", ["ChargeBee", "Kubernetes"]) == "the cat sat on the mat")
    }

    @Test func doesNotTouchShortCommonWords() {
        #expect(fix("be here now", ["bee"]) == "be here now")
    }

    @Test func preservesTrailingPunctuation() {
        #expect(fix("we love kubernetes.", ["Kubernetes"]) == "we love Kubernetes.")
    }

    @Test func levenshteinBasics() {
        #expect(FuzzyCorrector.levenshtein("kitten", "sitting") == 3)
        #expect(FuzzyCorrector.levenshtein("abc", "abc") == 0)
    }

    @Test func soundexGroupsLikeSounds() {
        #expect(FuzzyCorrector.soundex("Robert") == FuzzyCorrector.soundex("Rupert"))
        #expect(FuzzyCorrector.soundex("Postgres") == FuzzyCorrector.soundex("Postgress"))
    }
}
