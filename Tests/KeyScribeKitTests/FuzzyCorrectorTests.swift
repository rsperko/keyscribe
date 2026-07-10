import Testing
@testable import KeyScribeKit

private func fix(_ s: String, _ terms: [String]) -> String {
    FuzzyCorrector.apply(s, prepared: FuzzyCorrector.prepare(terms))
}

private func candidates(_ s: String, _ terms: [String]) -> [FuzzyCorrector.Candidate] {
    FuzzyCorrector.candidates(s, prepared: FuzzyCorrector.prepare(terms))
}

struct FuzzyCorrectorTests {
    @Test func snapsSplitProperNoun() {
        #expect(fix("we use charge bee for billing", ["ChargeBee"]) == "we use ChargeBee for billing")
    }

    @Test func fixesCasingAndSpacing() {
        #expect(fix("deploy to kubernetes today", ["Kubernetes"]) == "deploy to Kubernetes today")
        #expect(fix("the chargebee invoice", ["ChargeBee"]) == "the ChargeBee invoice")
    }

    // A correctly-cased split whose join equals the canonical exactly ("Fluid Audio" → FluidAudio)
    // must still merge — the only change is removing the inter-token space, which is a real edit, not
    // a no-op. The skip gate keys off "output identical to input", not "join equals canonical".
    @Test func mergesCorrectlyCasedSplit() {
        #expect(fix("we ship Fluid Audio today", ["FluidAudio"]) == "we ship FluidAudio today")
        #expect(fix("the web hook fired", ["webhook"]) == "the webhook fired")
    }

    // A single token already equal to the canonical is a true no-op and stays untouched, and a
    // casing-only single-token fix still snaps (the gate only skips when the output would be identical).
    @Test func leavesTrueSingleTokenNoOpUntouched() {
        #expect(fix("Redis is fast", ["Redis"]) == "Redis is fast")
        #expect(fix("redis, mostly", ["Redis"]) == "Redis, mostly")
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

    // Phonetic agreement must GATE a fuzzy snap, not merely buy a second edit. A common word
    // one edit from a dictionary term but phonetically distinct (different leading sound) must be left
    // alone — otherwise "Java" in the dictionary eats spoken "lava", "Rust" eats "dust". This is the
    // classic edit-distance false-positive band (Austria/Australia). A genuine same-sound misspelling
    // (postgress → Postgres) must still correct.
    @Test func doesNotSnapPhoneticallyDistinctNearMiss() {
        #expect(fix("i bought a lava lamp", ["Java"]) == "i bought a lava lamp")
        #expect(fix("the dust settled", ["Rust"]) == "the dust settled")
        #expect(fix("install postgress now", ["Postgres"]) == "install Postgres now")
    }

    // Soundex anchors on the literal first letter, so a mis-heard leading consonant that is
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

    // A clause comma between the two words ("spring, boot") is a sentence boundary, not a split term:
    // merging into "Spring Boot" would silently destroy the comma. A clean split still snaps, and a
    // terminator on the whole window's edge is preserved (it is not interior).
    @Test func multiTokenMergeDoesNotDropInteriorPunctuation() {
        #expect(fix("in spring, boot camp", ["Spring Boot"]) == "in spring, boot camp")
    }

    @Test func multiTokenMergeStillSnapsACleanSplit() {
        #expect(fix("in spring boot camp", ["Spring Boot"]) == "in Spring Boot camp")
    }

    @Test func multiTokenMergePreservesWholeWindowTrailingPunctuation() {
        #expect(fix("we use spring boot.", ["Spring Boot"]) == "we use Spring Boot.")
    }

    // Interior punctuation glued INSIDE a single token ("git-hub", "spring,boot") would be erased by
    // normalize() and never re-emitted (only outer-edge punctuation survives), so the window is left
    // untouched rather than snapped to the canonical term.
    @Test func doesNotDeleteInteriorPunctuationInASingleToken() {
        #expect(fix("git-hub", ["GitHub"]) == "git-hub")
        #expect(fix("spring,boot", ["Spring Boot"]) == "spring,boot")
    }

    // A LiveEdits control char glued inside a token ("git\nhub" from "insert new line") is command
    // output, not a spelling: normalize() strips it, so snapping to "GitHub" would erase the dictated
    // newline. The window is skipped; an ordinary-space split still snaps.
    @Test func doesNotEraseAControlCharGluedInsideAToken() {
        #expect(fix("git\nhub", ["GitHub"]) == "git\nhub")
        #expect(fix("git\thub", ["GitHub"]) == "git\thub")
    }

    @Test func stillSnapsAcrossOrdinarySpace() {
        #expect(fix("git hub", ["GitHub"]) == "GitHub")
    }

    // candidates() shares apply()'s exact walk + gates, but surfaces each near-miss as a
    // (heard → canonical) pair for the LLM to adjudicate instead of rewriting the text.
    @Test func candidatesSurfacesSplitProperNoun() {
        #expect(candidates("we use charge bee for billing", ["ChargeBee"])
            == [.init(heard: "charge bee", canonical: "ChargeBee")])
    }

    @Test func candidatesSurfacesFuzzyMishearing() {
        #expect(candidates("install postgress now", ["Postgres"])
            == [.init(heard: "postgress", canonical: "Postgres")])
    }

    // A term already spelled correctly is not a recovery candidate — it is covered by the
    // separate validTerms "treat as correct" hint. Only genuine near-misses surface here.
    @Test func candidatesExcludesVerbatimTerm() {
        #expect(candidates("we use ChargeBee for billing", ["ChargeBee"]).isEmpty)
    }

    @Test func candidatesLeavesUnrelatedWordsAlone() {
        #expect(candidates("the cat sat on the mat", ["ChargeBee", "Kubernetes"]).isEmpty)
    }

    // Same phonetic gate as apply(): a common word one edit from a term but distinct in sound
    // is not surfaced (no "lava" → Java).
    @Test func candidatesRespectsPhoneticGate() {
        #expect(candidates("i bought a lava lamp", ["Java"]).isEmpty)
    }

    @Test func candidatesDedupesRepeatedMishearing() {
        #expect(candidates("postgress and postgress again", ["Postgres"])
            == [.init(heard: "postgress", canonical: "Postgres")])
    }

    // Inherited from the shared walk: a window overlapping a ⟦SN:…⟧ nonce is never matched, so a
    // near-miss glued to a token is not surfaced as a candidate.
    @Test func candidatesSkipsWindowTouchingANonce() {
        #expect(candidates("in spring \(SentinelText.open)V:1⟧ camp", ["Spring Boot"]).isEmpty)
    }
}
