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

    @Test func mergesCorrectlyCasedSplit() {
        #expect(fix("we ship Fluid Audio today", ["FluidAudio"]) == "we ship FluidAudio today")
        #expect(fix("the web hook fired", ["webhook"]) == "the webhook fired")
    }

    @Test func leavesTrueSingleTokenNoOpUntouched() {
        #expect(fix("Redis is fast", ["Redis"]) == "Redis is fast")
        #expect(fix("redis, mostly", ["Redis"]) == "Redis, mostly")
    }

    @Test func correctsSmallMisspelling() {
        #expect(fix("install postgress now", ["Postgres"]) == "install Postgres now")
    }

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
        #expect(FuzzyCorrector.phoneticKey("Celery") == FuzzyCorrector.phoneticKey("Sellery"))
        #expect(FuzzyCorrector.phoneticKey("Java") != FuzzyCorrector.phoneticKey("Lava"))
    }

    @Test func doesNotSnapPhoneticallyDistinctNearMiss() {
        #expect(fix("i bought a lava lamp", ["Java"]) == "i bought a lava lamp")
        #expect(fix("the dust settled", ["Rust"]) == "the dust settled")
        #expect(fix("install postgress now", ["Postgres"]) == "install Postgres now")
    }

    @Test func recoversLeadingConsonantHomophone() {
        #expect(fix("run the sellery worker", ["Celery"]) == "run the Celery worker")
    }

    @Test func doesNotSnapDistanceTwoOnAShortWord() {
        #expect(fix("please install mane now", ["Mono"]) == "please install mane now")
    }

    @Test func multiTokenMergeDoesNotDropInteriorPunctuation() {
        #expect(fix("in spring, boot camp", ["Spring Boot"]) == "in spring, boot camp")
    }

    @Test func multiTokenMergeStillSnapsACleanSplit() {
        #expect(fix("in spring boot camp", ["Spring Boot"]) == "in Spring Boot camp")
    }

    @Test func multiTokenMergePreservesWholeWindowTrailingPunctuation() {
        #expect(fix("we use spring boot.", ["Spring Boot"]) == "we use Spring Boot.")
    }

    @Test func doesNotDeleteInteriorPunctuationInASingleToken() {
        #expect(fix("git-hub", ["GitHub"]) == "git-hub")
        #expect(fix("spring,boot", ["Spring Boot"]) == "spring,boot")
    }

    @Test func doesNotEraseAControlCharGluedInsideAToken() {
        #expect(fix("git\nhub", ["GitHub"]) == "git\nhub")
        #expect(fix("git\thub", ["GitHub"]) == "git\thub")
    }

    @Test func stillSnapsAcrossOrdinarySpace() {
        #expect(fix("git hub", ["GitHub"]) == "GitHub")
    }

    @Test func candidatesSurfacesSplitProperNoun() {
        #expect(candidates("we use charge bee for billing", ["ChargeBee"])
            == [.init(heard: "charge bee", canonical: "ChargeBee")])
    }

    @Test func candidatesSurfacesFuzzyMishearing() {
        #expect(candidates("install postgress now", ["Postgres"])
            == [.init(heard: "postgress", canonical: "Postgres")])
    }

    @Test func candidatesExcludesVerbatimTerm() {
        #expect(candidates("we use ChargeBee for billing", ["ChargeBee"]).isEmpty)
    }

    @Test func candidatesLeavesUnrelatedWordsAlone() {
        #expect(candidates("the cat sat on the mat", ["ChargeBee", "Kubernetes"]).isEmpty)
    }

    @Test func candidatesRespectsPhoneticGate() {
        #expect(candidates("i bought a lava lamp", ["Java"]).isEmpty)
    }

    @Test func candidatesDedupesRepeatedMishearing() {
        #expect(candidates("postgress and postgress again", ["Postgres"])
            == [.init(heard: "postgress", canonical: "Postgres")])
    }

    @Test func candidatesSkipsWindowTouchingANonce() {
        #expect(candidates("in spring \(SentinelText.open)V:1⟧ camp", ["Spring Boot"]).isEmpty)
    }
}
