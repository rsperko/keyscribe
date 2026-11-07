import Testing
@testable import KeyScribeKit

struct MishearingHintTests {
    @Test func aWordThatSoundsLikeADictionaryNameIsPointedOut() {
        let hints = MishearingHint.find(heard: "Cryden, create a pane for me", dictionary: ["Kryten"], stages: [])
        #expect(hints == [MishearingHint.Hint(phrase: "Cryden", term: "Kryten")])
    }

    @Test func aPhraseARuleAlreadyFixesIsNotPointedOut() {
        let stages: [any PipelineStage] = [ReplacementsStage(rules: [ReplacementRule(heard: "cryden", replace: "Kryten", isRegex: false)])]
        #expect(MishearingHint.find(heard: "Cryden, create a pane for me", dictionary: ["Kryten"], stages: stages).isEmpty)
    }

    @Test func aNameWrittenCorrectlyIsNotPointedOut() {
        #expect(MishearingHint.find(heard: "Kryten, create a pane", dictionary: ["Kryten"], stages: []).isEmpty)
    }

    @Test func aWordInAnotherScriptIsNotPointedOut() {
        #expect(MishearingHint.find(heard: "статус готов", dictionary: ["Kryten"], stages: []).isEmpty)
    }

    @Test func eachDictionaryWordIsPointedOutOnceWithItsLikeliestMishearing() {
        let hints = MishearingHint.find(heard: "Cryden said Crayton was here", dictionary: ["Kryten"], stages: [])
        #expect(hints.count == 1)
        #expect(hints.first?.term == "Kryten")
    }

    @Test func nothingIsPointedOutWithAnEmptyDictionary() {
        #expect(MishearingHint.find(heard: "Cryden", dictionary: [], stages: []).isEmpty)
    }
}
