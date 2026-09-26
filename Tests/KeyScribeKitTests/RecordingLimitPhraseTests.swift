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
