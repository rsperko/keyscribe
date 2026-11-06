import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct TakeRecorderTests {
    @Test func theLimitCommitsATakeStillRecordingAndRecordsItsDeadline() async {
        let recorder = TakeRecorder()
        let reached = Signal()
        recorder.startLimit(seconds: 0.01, stillRecording: { true }, reached: { reached.fire() })
        #expect(recorder.limitSeconds == 0.01)
        #expect(recorder.deadline != nil)
        await reached.wait()
        #expect(reached.hasFired)
    }

    @Test func theLimitLeavesATakeThatAlreadyStoppedAlone() async throws {
        let recorder = TakeRecorder()
        var reached = false
        recorder.startLimit(seconds: 0.01, stillRecording: { false }, reached: { reached = true })
        try await Task.sleep(for: .milliseconds(60))
        #expect(!reached)
    }

    @Test func aStoppedLimitNeverFires() async throws {
        let recorder = TakeRecorder()
        var reached = false
        recorder.startLimit(seconds: 0.02, stillRecording: { true }, reached: { reached = true })
        recorder.stopLimit()
        try await Task.sleep(for: .milliseconds(80))
        #expect(!reached)
    }

    @Test func theLevelPollStopsOnceRecordingEnds() async throws {
        let recorder = TakeRecorder()
        var ticks = 0
        let stopped = Signal()
        recorder.pollLevel {
            ticks += 1
            if ticks == 3 { stopped.fire(); return false }
            return true
        }
        await stopped.wait()
        try await Task.sleep(for: .milliseconds(80))
        #expect(ticks == 3)
    }

    @Test func aTakeThatNeverStreamedHasNothingToFinalizeOrRelease() async {
        let recorder = TakeRecorder()
        #expect(!recorder.isStreaming)
        #expect(await recorder.finalizeStreaming(gate: SingleFlightDeadline(), timeout: 1) == nil)
        #expect(recorder.tearDown() == nil)
    }
}
