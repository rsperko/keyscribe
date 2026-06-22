import Testing
@testable import KeyScribeKit

struct DictationMachineTests {
    @Test func happyPathProgressesToInserted() {
        var m = DictationMachine()
        #expect(m.state == .idle)
        #expect(m.beginRecording() == true)
        #expect(m.state == .recording)
        m.beginTranscribing()
        #expect(m.state == .transcribing)
        m.beginInserting()
        #expect(m.state == .inserting)
        m.finish(.inserted)
        #expect(m.state == .finished(.inserted))
    }

    @Test func overlappingDictationIsRejectedWhileBusy() {
        var m = DictationMachine()
        #expect(m.beginRecording() == true)
        #expect(m.isBusy == true)
        #expect(m.beginRecording() == false)
        m.beginTranscribing()
        #expect(m.beginRecording() == false)
    }

    @Test func canStartAgainAfterFinish() {
        var m = DictationMachine()
        _ = m.beginRecording()
        m.beginTranscribing()
        m.beginInserting()
        m.finish(.inserted)
        #expect(m.isBusy == false)
        #expect(m.beginRecording() == true)
    }

    @Test func outcomeMapsInsertDecision() {
        #expect(DictationMachine.outcome(for: .insert) == .inserted)
        #expect(DictationMachine.outcome(for: .clipboardFallback(reason: .appChanged)) == .copied(.appChanged))
        #expect(DictationMachine.outcome(for: .clipboardFallback(reason: .accessibilityDenied)) == .copied(.accessibilityDenied))
    }

    @Test func emptyTranscriptIsNoSpeech() {
        #expect(DictationMachine.outcomeForTranscript("", decision: .insert) == .noSpeech)
        #expect(DictationMachine.outcomeForTranscript("   ", decision: .insert) == .noSpeech)
        #expect(DictationMachine.outcomeForTranscript("hello", decision: .insert) == .inserted)
    }

    @Test func cancelReturnsToIdle() {
        var m = DictationMachine()
        _ = m.beginRecording()
        m.cancel()
        #expect(m.state == .idle)
        #expect(m.beginRecording() == true)
    }
}
