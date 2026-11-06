import Testing
@testable import KeyScribeKit

struct SpokenVoicesTests {
    @Test func theRecommendedVoiceLeadsTheListAndIsTheDefault() {
        #expect(SpokenVoices.recommended == "af_heart")
        #expect(SpokenVoices.all.first?.id == "af_heart")
        #expect(SpokenVoices.resolved(nil) == "af_heart")
    }

    @Test func onlyTheBestGradedEnglishSpeakersAreOffered() {
        #expect(Set(SpokenVoices.all.map(\.id)) == [
            "af_heart", "af_bella", "af_nicole", "af_aoede", "af_kore", "af_sarah",
            "am_fenrir", "am_michael", "am_puck", "bf_emma",
        ])
        #expect(Set(SpokenVoices.all.map(\.id)).count == SpokenVoices.all.count)
    }

    @Test func aSavedVoiceInTheListIsKeptAndAnythingElseFallsBackToTheRecommendedOne() {
        #expect(SpokenVoices.resolved("bf_emma") == "bf_emma")
        #expect(SpokenVoices.resolved("com.apple.voice.compact.en-US.Samantha") == "af_heart")
        #expect(SpokenVoices.resolved("") == "af_heart")
        #expect(SpokenVoices.resolved("zf_xiaobei") == "af_heart")
        #expect(SpokenVoices.resolved("bm_george") == "af_heart")
    }

    @Test func aVoiceIsLabeledWithItsNameAccentAndVoiceAndTheRecommendedOneSaysSo() {
        let heart = SpokenVoices.all.first { $0.id == "af_heart" }
        let emma = SpokenVoices.all.first { $0.id == "bf_emma" }
        let puck = SpokenVoices.all.first { $0.id == "am_puck" }
        #expect(heart?.label == "Heart \u{00B7} American, female (Recommended)")
        #expect(emma?.label == "Emma \u{00B7} British, female")
        #expect(puck?.label == "Puck \u{00B7} American, male")
    }

    @Test func afterTheRecommendedVoiceTheListIsOrderedByAccentThenName() {
        let rest = SpokenVoices.all.dropFirst().map(\.id)
        let sorted = rest.sorted { lhs, rhs in
            let order = ["af_", "am_", "bf_", "bm_"]
            let l = order.firstIndex(of: String(lhs.prefix(3)))!, r = order.firstIndex(of: String(rhs.prefix(3)))!
            return l == r ? lhs < rhs : l < r
        }
        #expect(rest == sorted)
    }
}
