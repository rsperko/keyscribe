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

    @Test func adversarialPhrasesAreNotRewritten() {
        let pairs: [(phrase: String, term: String)] = [
            ("this is a fast app", "FastAPI"),
            ("please open app settings", "OpenAPI"),
            ("get lab results", "GitLab"),
            ("the sales farce continued", "Salesforce"),
            ("there is an air flaw in the design", "Airflow"),
            ("a grey log fell in the river", "Graylog"),
            ("the mail chump arrived", "Mailchimp"),
            ("the data dig is done", "Datadog"),
            ("the fire bass was loud", "Firebase"),
            ("the centre of the room", "Accenture"),
            ("put the crate here", "Accurate"),
            ("cabernets are on sale", "Kubernetes"),
            ("the post grass was cut", "Postgres"),
            ("we met at Deutsche Bank", "Deutsche Bank"),
        ]
        for pair in pairs {
            #expect(fix(pair.phrase, [pair.term]) == pair.phrase)
            #expect(candidates(pair.phrase, [pair.term]).isEmpty)
        }
    }

    @Test func exactJoinOfTwoCommonWordsStillRewrites() {
        #expect(fix("the red is bright", ["Redis"]) == "the Redis bright")
        #expect(fix("a work day", ["Workday"]) == "a Workday")
        #expect(fix("the key chain", ["Keychain"]) == "the Keychain")
    }

    @Test func everydayWordsNearALongTermAreLeftAlone() {
        let pairs: [(phrase: String, term: String)] = [
            ("we took photos during the golden hour", "GoldenEye"),
            ("there is a silver lining", "Silvereye"),
            ("we will grant access tomorrow", "Guaranty"),
            ("we held a rally yesterday", "Aerially"),
            ("we drove to Bolton yesterday", "Abolition"),
            ("a sprat swam past the boat", "Separate"),
            ("a sprat swam past the boat", "Aspirate"),
        ]
        for pair in pairs {
            #expect(fix(pair.phrase, [pair.term]) == pair.phrase)
            #expect(candidates(pair.phrase, [pair.term]).isEmpty)
        }
    }

    @Test func droppedLettersBeyondTheEditCapAreNotRecovered() {
        #expect(fix("the UGBte cluster", ["Yugabyte"]) == "the UGBte cluster")
    }

    @Test func replacementOutputIsNotRewrittenByFuzzyStage() {
        var ctx = PipelineContext(text: "We scheduled a meeting yesterday.")
        ReplacementsStage(rules: [ReplacementRule(heard: "meeting", replace: "rally", isRegex: false)]).apply(&ctx)
        FuzzyStage(terms: ["Aerially"]).apply(&ctx)
        #expect(ctx.text == "We scheduled a rally yesterday.")
    }

    @Test func neverFuzzesAWordThePhoneticKeyCannotSee() {
        let pairs: [(phrase: String, term: String)] = [
            ("мы были в Москве", "Москва"),
            ("я перевёл деньги в Сбербанка", "Сбербанк"),
            ("это собака", "соната"),
            ("он привез подарок", "привет"),
            ("ο φίλος μου", "φιλος"),
            ("クバネテス を使う", "クバネティス"),
        ]
        for pair in pairs {
            #expect(fix(pair.phrase, [pair.term]) == pair.phrase)
            #expect(candidates(pair.phrase, [pair.term]).isEmpty)
        }
    }

    @Test func nonLatinTermsStillSnapCasingAndSpacing() {
        #expect(fix("мы были в москва", ["Москва"]) == "мы были в Москва")
        #expect(fix("клиенты сбер банк", ["Сбербанк"]) == "клиенты Сбербанк")
    }

    @Test func accentedLatinTermsStillRecover() {
        #expect(fix("the cafe opens", ["Café"]) == "the Café opens")
        #expect(fix("ask Jose now", ["José"]) == "ask José now")
    }

    @Test func latinLettersWithoutAnAccentFormStillRecover() {
        #expect(fix("we met on Strasse road", ["Straße"]) == "we met on Straße road")
        #expect(fix("we met on Strase road", ["Straße"]) == "we met on Straße road")
        #expect(fix("ask Bjorn now", ["Bjørn"]) == "ask Bjørn now")
        #expect(fix("the Aesir saga", ["Æsir"]) == "the Æsir saga")
        #expect(fix("his oeuvre grew", ["Œuvre"]) == "his Œuvre grew")
        #expect(fix("we flew to Lodz", ["Łódź"]) == "we flew to Łódź")
    }

    @Test func aSixLetterWordGetsOnlyOneEdit() {
        #expect(fix("a cloudy morning", ["Claude"]) == "a cloudy morning")
        #expect(fix("grant access now", ["Chess"]) == "grant access now")
        #expect(fix("ask Sophia now", ["Sofia"]) == "ask Sophia now")
    }

    @Test func aSevenLetterWordStillGetsTwoEdits() {
        #expect(fix("open Gravena now", ["Grafana"]) == "open Grafana now")
    }

    @Test func knownLimitationOneEditOnAShortSameKeyWordSnaps() {
        #expect(fix("rebake the branch", ["rebase"]) == "rebase the branch")
        #expect(fix("take a rest", ["Rust"]) == "take a Rust")
        #expect(fix("ask Yuka", ["Yuki"]) == "ask Yuki")
    }
}
