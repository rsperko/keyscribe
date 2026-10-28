import Testing
@testable import KeyScribeKit

struct RecordingLimitPhraseTests {
    @Test func wholeMinutesReadAsMinutes() {
        #expect(RecordingLimit.phrase(seconds: 300) == "5-minute")
        #expect(RecordingLimit.phrase(seconds: 60) == "1-minute")
    }

    @Test func aLimitThatIsNotAWholeMinuteIsStatedInSeconds() {
        #expect(RecordingLimit.phrase(seconds: 90) == "90-second")
        #expect(RecordingLimit.phrase(seconds: 0.05) == "1-second")
    }
}

struct RecordingLimitSecondsTests {
    @Test func aModelWithoutItsOwnLimitGetsTheBackstop() {
        #expect(RecordingLimit.modelLimit(engineId: "parakeet") == nil)
        #expect(RecordingLimit.modelLimit(engineId: "not-in-the-catalog") == nil)
        #expect(RecordingLimit.seconds(backstop: 900, modelLimit: nil) == 900)
    }

    @Test func aModelThatDegradesOnLongTakesStopsAtItsOwnLimit() {
        #expect(RecordingLimit.modelLimit(engineId: "qwen3-asr-0.6b") == 480)
        #expect(RecordingLimit.modelLimit(engineId: "qwen3-asr-1.7b") == 720)
        #expect(RecordingLimit.seconds(backstop: 900, modelLimit: 480) == 480)
    }

    @Test func aBackstopBelowTheModelsLimitStillWins() {
        #expect(RecordingLimit.seconds(backstop: 60, modelLimit: 720) == 60)
    }

    @Test func everyQwen3TakeFitsTheModelsInput() {
        for model in SpeechModelCatalog.all where model.kind == .qwen3asr {
            let limit = RecordingLimit.seconds(
                backstop: RecordingLimit.backstopSeconds, modelLimit: RecordingLimit.modelLimit(engineId: model.id))
            #expect(Qwen3OutputBudget.accepts(audioSeconds: limit), "\(model.id)")
        }
    }
}
