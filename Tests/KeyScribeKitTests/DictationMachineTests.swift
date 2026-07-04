import Testing
@testable import KeyScribeKit

struct DictationMachineTests {
    @Test func happyPathProgressesToInserted() {
        var m = DictationMachine()
        #expect(m.state == .idle)
        #expect(m.beginArming() == true)
        #expect(m.state == .arming)
        #expect(m.markRecording() == true)
        #expect(m.state == .recording)
        #expect(m.beginTranscribing() == true)
        #expect(m.state == .transcribing)
        #expect(m.beginInserting() == true)
        #expect(m.state == .inserting)
        m.finish(.inserted)
        #expect(m.state == .finished(.inserted))
    }

    @Test func overlappingDictationIsRejectedWhileBusy() {
        var m = DictationMachine()
        #expect(m.beginArming() == true)
        #expect(m.isBusy == true)
        #expect(m.beginArming() == false)
        _ = m.markRecording()
        #expect(m.beginArming() == false)
        _ = m.beginTranscribing()
        #expect(m.beginArming() == false)
    }

    @Test func canStartAgainAfterFinish() {
        var m = DictationMachine()
        _ = m.beginArming()
        _ = m.markRecording()
        _ = m.beginTranscribing()
        _ = m.beginInserting()
        m.finish(.inserted)
        #expect(m.isBusy == false)
        #expect(m.beginArming() == true)
    }

    @Test func transitionsAreGuardedToTheirSourceState() {
        var m = DictationMachine()
        // markRecording only from arming.
        #expect(m.markRecording() == false)
        // beginTranscribing only from recording (not arming).
        _ = m.beginArming()
        #expect(m.beginTranscribing() == false)
        _ = m.markRecording()
        // beginInserting only from transcribing (not recording).
        #expect(m.beginInserting() == false)
        #expect(m.beginTranscribing() == true)
        #expect(m.beginInserting() == true)
        // No further transitions out of inserting.
        #expect(m.markRecording() == false)
        #expect(m.beginTranscribing() == false)
    }

    @Test func beginInsertingRejectsASecondInsert() {
        var m = DictationMachine()
        _ = m.beginArming()
        _ = m.markRecording()
        _ = m.beginTranscribing()
        #expect(m.beginInserting() == true)
        #expect(m.beginInserting() == false)
    }

    @Test func cancellingBringUpIsBusyButNotCancellableAndReturnsToIdle() {
        var m = DictationMachine()
        _ = m.beginArming()
        #expect(m.beginCancellingBringUp() == true)
        #expect(m.state == .cancellingBringUp)
        #expect(m.isBusy == true)
        #expect(m.isCancellable == false)
        m.cancel()
        #expect(m.state == .idle)
        #expect(m.beginArming() == true)
    }

    @Test func beginCancellingBringUpOnlyFromArming() {
        var m = DictationMachine()
        #expect(m.beginCancellingBringUp() == false)
        _ = m.beginArming()
        _ = m.markRecording()
        #expect(m.beginCancellingBringUp() == false)
    }

    @Test func cancellabilityTracksTheState() {
        var m = DictationMachine()
        #expect(m.isCancellable == false)
        _ = m.beginArming()
        #expect(m.isCancellable == true)
        _ = m.markRecording()
        #expect(m.isCancellable == true)
        _ = m.beginTranscribing()
        #expect(m.isCancellable == true)
        _ = m.beginInserting()
        #expect(m.isCancellable == false)
    }

    @Test func finishIsReachableFromAnyLiveState() {
        var m = DictationMachine()
        _ = m.beginArming()
        m.finish(.failed)
        #expect(m.state == .finished(.failed))
        #expect(m.isBusy == false)
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
        _ = m.beginArming()
        _ = m.markRecording()
        m.cancel()
        #expect(m.state == .idle)
        #expect(m.beginArming() == true)
    }
}
