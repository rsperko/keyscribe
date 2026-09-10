import Testing
@testable import KeyScribeKit

struct CorpusRunVerdictTests {
    private let clips = ["c1", "c2", "c3"]

    private func allTranscribed(_ engines: [String]) -> CorpusRunVerdict {
        var verdict = CorpusRunVerdict(engineIds: engines, clipIds: clips)
        for engine in engines {
            for clip in clips { verdict.record(engine: engine, clip: clip, outcome: .transcribed) }
        }
        return verdict
    }

    @Test func everyClipTranscribedByEveryEnginePasses() {
        let verdict = allTranscribed(["a", "b"])
        #expect(verdict.passed)
        #expect(verdict.failures.isEmpty)
        #expect(CorpusRunOutcome.ran(verdict).exitCode == 0)
    }

    @Test func oneSuccessAndEveryOtherClipFailedFails() {
        let many = (1...107).map { "c\($0)" }
        var verdict = CorpusRunVerdict(engineIds: ["a"], clipIds: many)
        verdict.record(engine: "a", clip: "c1", outcome: .transcribed)
        for clip in many.dropFirst() { verdict.record(engine: "a", clip: clip, outcome: .failed("boom")) }
        #expect(!verdict.passed)
        #expect(verdict.failures.count == 106)
        #expect(CorpusRunOutcome.ran(verdict).exitCode == 1)
    }

    @Test func missingAudioFails() {
        var verdict = allTranscribed(["a"])
        verdict.record(engine: "a", clip: "c2", outcome: .missingAudio)
        #expect(verdict.failures == [.init(engine: "a", clip: "c2", reason: "audio missing")])
    }

    @Test func aClipNeverRecordedFails() {
        var verdict = CorpusRunVerdict(engineIds: ["a"], clipIds: clips)
        verdict.record(engine: "a", clip: "c1", outcome: .transcribed)
        verdict.record(engine: "a", clip: "c3", outcome: .transcribed)
        #expect(verdict.failures == [.init(engine: "a", clip: "c2", reason: "not run")])
    }

    @Test func aLoadFailureFailsThatEngineOnceAndLeavesOthersClean() {
        var verdict = allTranscribed(["a", "b"])
        verdict.recordLoadFailure(engine: "b", reason: "no shaders")
        #expect(verdict.failures == [.init(engine: "b", clip: nil, reason: "failed to load: no shaders")])
        #expect(verdict.failedEngineIds == ["b"])
    }

    @Test func zeroEnginesFails() {
        let verdict = CorpusRunVerdict(engineIds: [], clipIds: clips)
        #expect(!verdict.passed)
        #expect(CorpusRunOutcome.ran(verdict).exitCode == 1)
    }

    @Test func zeroClipsFails() {
        #expect(!CorpusRunVerdict(engineIds: ["a"], clipIds: []).passed)
    }

    @Test func anInvocationErrorExitsTwo() {
        #expect(CorpusRunOutcome.invocationError("could not read manifest.json").exitCode == 2)
    }

    @Test func failureLinesNameTheEngineAndClip() {
        #expect(CorpusRunVerdict.Failure(engine: "a", clip: "c2", reason: "audio missing").line
            == "FAIL — a c2: audio missing")
        #expect(CorpusRunVerdict.Failure(engine: "b", clip: nil, reason: "failed to load: x").line
            == "FAIL — b: failed to load: x")
        #expect(CorpusRunVerdict.Failure(engine: nil, clip: nil, reason: "no engine ran").line
            == "FAIL — no engine ran")
    }
}
