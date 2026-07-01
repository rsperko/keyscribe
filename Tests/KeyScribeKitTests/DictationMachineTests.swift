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
        #expect(DictationMachine.outcomeForTranscript(finalText: "", heard: "", decision: .insert) == .noSpeech)
        #expect(DictationMachine.outcomeForTranscript(finalText: "   ", heard: "   ", decision: .insert) == .noSpeech)
        #expect(DictationMachine.outcomeForTranscript(finalText: "hello", heard: "hello", decision: .insert) == .inserted)
    }

    @Test(arguments: [
        ("insert new line", "\n"),
        ("insert new paragraph", "\n\n"),
        ("insert tab character", "\t"),
    ])
    func controlOnlyUtteranceIsNotNoSpeech(phrase: String, control: String) {
        var ctx = PipelineContext(text: phrase)
        LiveEditsStage().apply(&ctx)
        #expect(ctx.text == control)
        #expect(DictationMachine.outcomeForTranscript(finalText: control, heard: phrase, decision: .insert) == .inserted)
    }

    @Test func heardSpeechButEmptyFinalIsNoSpeech() {
        #expect(DictationMachine.outcomeForTranscript(finalText: "", heard: "switch to email mode", decision: .insert) == .noSpeech)
    }

    @Test func cancelReturnsToIdle() {
        var m = DictationMachine()
        _ = m.beginRecording()
        m.cancel()
        #expect(m.state == .idle)
        #expect(m.beginRecording() == true)
    }
}
