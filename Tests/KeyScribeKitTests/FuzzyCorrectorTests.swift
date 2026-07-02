import Testing
@testable import KeyScribeKit

private func fix(_ s: String, _ terms: [String]) -> String {
    FuzzyCorrector.apply(s, prepared: FuzzyCorrector.prepare(terms))
}

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

    // Length-bucketing must not change which term wins: a far-length distractor is never a candidate,
    // and the correct in-budget term is still chosen.
    @Test func picksLengthCompatibleTermOverFarLengthDistractor() {
        let terms = ["Postgres", "PostgresqlReplicationController"]
        #expect(fix("install postgress now", terms) == "install Postgres now")
    }

    @Test func stillSnapsCloseLongTerm() {
        #expect(fix("the kabernetas cluster", ["Kubernetes"]) == "the Kubernetes cluster")
    }

    @Test func doesNotSnapDistantSoundAlike() {
        #expect(fix("the kabernatas cluster", ["Kubernetes"]) == "the kabernatas cluster")
    }

    @Test func tieBreaksToPhoneticMatchNotDeclarationOrder() {
        #expect(fix("i need a halper now", ["Halter", "Helper"]) == "i need a Helper now")
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

    @Test func phoneticKeyGroupsLikeSounds() {
        #expect(FuzzyCorrector.phoneticKey("Robert") == FuzzyCorrector.phoneticKey("Rupert"))
        #expect(FuzzyCorrector.phoneticKey("Postgres") == FuzzyCorrector.phoneticKey("Postgress"))
        // First letter is coded (not kept literal), so a soft C and an S share a key — the exact
        // Soundex weakness the gate depends on.
        #expect(FuzzyCorrector.phoneticKey("Celery") == FuzzyCorrector.phoneticKey("Sellery"))
        // Distinct leading sounds stay distinct, so the gate can reject a near-miss.
        #expect(FuzzyCorrector.phoneticKey("Java") != FuzzyCorrector.phoneticKey("Lava"))
    }

    // Audit #2: phonetic agreement must GATE a fuzzy snap, not merely buy a second edit. A common word
    // one edit from a dictionary term but phonetically distinct (different leading sound) must be left
    // alone — otherwise "Java" in the dictionary eats spoken "lava", "Rust" eats "dust". This is the
    // classic edit-distance false-positive band (Austria/Australia). A genuine same-sound misspelling
    // (postgress → Postgres) must still correct.
    @Test func doesNotSnapPhoneticallyDistinctNearMiss() {
        #expect(fix("i bought a lava lamp", ["Java"]) == "i bought a lava lamp")
        #expect(fix("the dust settled", ["Rust"]) == "the dust settled")
        #expect(fix("install postgress now", ["Postgres"]) == "install Postgres now")
    }

    // Audit #1: Soundex anchors on the literal first letter, so a mis-heard leading consonant that is
    // phonetically identical (soft C ≡ S) yields different codes and the phonetic +1 never fires —
    // "sellery" (a plausible mishearing of soft-C "Celery") is two edits away and stays uncorrected.
    // A first-letter-insensitive phonetic key (Double Metaphone: both → "SLR") would grant the edit and
    // recover it.
    @Test func recoversLeadingConsonantHomophone() {
        #expect(fix("run the sellery worker", ["Celery"]) == "run the Celery worker")
    }

    @Test func doesNotSnapDistanceTwoOnAShortWord() {
        #expect(fix("please install mane now", ["Mono"]) == "please install mane now")
    }
}
