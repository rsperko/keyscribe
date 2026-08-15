import XCTest
@testable import KeyScribeApp
import KeyScribeKit

@MainActor
final class SpeechModelsModelTests: XCTestCase {
    private final class Recorder {
        struct Failure: Error {}

        var deferred: [() -> Void] = []
        var evicted: [String] = []
        var removed: [String] = []
        var markedInstalled: [String] = []
        var markedRemoved: [String] = []
        var markedFailed: [String] = []
        var clearedFailed: [String] = []
        var activeChanges: [String] = []
        var removeShouldFail = false
        var markInstalledShouldFail = false
        var markRemovedShouldFail = false
    }

    private func makeModel(
        recorder: Recorder,
        verifyResult: ModelVerificationResult = .skipped,
        activeId: String = "parakeet-tdt-ctc-110m",
        initialFailedIds: Set<String>? = nil,
        deferWhileBusy: ((@escaping () -> Void) -> Void)? = nil,
        download: @escaping (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void = { _, _ in }
    ) -> SpeechModelsModel {
        SpeechModelsModel(
            activeId: activeId,
            stt: Settings.defaults.stt,
            download: download,
            verify: { _ in verifyResult },
            evictEngine: { id in recorder.evicted.append(id) },
            onActiveChange: { recorder.activeChanges.append($0) },
            onDictionaryMatchingChange: { _ in },
            deferWhileBusy: deferWhileBusy ?? { $0() },
            initialInstalledIds: ["parakeet-tdt-ctc-110m", "parakeet"],
            initialFailedIds: initialFailedIds,
            removeFiles: {
                recorder.removed.append($0)
                if recorder.removeShouldFail { throw Recorder.Failure() }
            },
            markInstalled: {
                recorder.markedInstalled.append($0)
                if recorder.markInstalledShouldFail { throw Recorder.Failure() }
            },
            markRemoved: {
                recorder.markedRemoved.append($0)
                if recorder.markRemovedShouldFail { throw Recorder.Failure() }
            },
            markFailed: { recorder.markedFailed.append($0) },
            clearFailed: { recorder.clearedFailed.append($0) })
    }

    // Holds a download open without a wall-clock sleep, and fails it on release. A 60 s sleep outlived the
    // test, kept the model alive, and on completion would reach VADModel.ensureInBackground — a real
    // download firing during unrelated tests. Releasing with an error takes the failure path instead, which
    // never touches VAD.
    private final class DownloadGate: @unchecked Sendable {
        struct Released: Error {}
        private let held = DispatchSemaphore(value: 0)
        func hold() async throws {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread { [held] in
                    held.wait()
                    c.resume()
                }
            }
            throw Released()
        }
        func release() { held.signal() }
    }

    private func settleTasks() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // Yielding a fixed number of times does not guarantee a native waiter resumed and its task unwound.
    // Bounded so a regression FAILS here instead of hanging the suite.
    private func waitUntil(
        _ condition: () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for \(message)", file: file, line: line)
    }

    private func row(_ id: String, in model: SpeechModelsModel) throws -> SpeechModelsModel.Row {
        try XCTUnwrap(model.rows.first { $0.id == id })
    }

    func testDeleteDefersFileRemovalUntilIdleHookRuns() async throws {
        let recorder = Recorder()
        let model = makeModel(
            recorder: recorder,
            deferWhileBusy: { recorder.deferred.append($0) })

        model.requestDelete("parakeet")
        XCTAssertEqual(model.pendingDeleteId, "parakeet")
        model.confirmDelete()
        await settleTasks()

        XCTAssertEqual(recorder.evicted, ["parakeet"])
        XCTAssertEqual(recorder.markedRemoved, [])
        XCTAssertEqual(recorder.removed, [])
        XCTAssertEqual(recorder.deferred.count, 1)
        XCTAssertTrue(try row("parakeet", in: model).isUsable)
        XCTAssertEqual(try row("parakeet", in: model).downloadPhase, "Removing…")

        recorder.deferred[0]()
        await settleTasks()

        XCTAssertEqual(recorder.removed, ["parakeet"])
        XCTAssertEqual(recorder.markedRemoved, ["parakeet"])
        XCTAssertFalse(try row("parakeet", in: model).isUsable)
    }

    // Partial weights must be wiped so a retry starts clean and the model never becomes an "on disk but
    // not installed" phantom with no delete affordance.
    func testFailedDownloadWipesPartialFiles() async throws {
        struct Boom: Error {}
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, download: { _, _ in throw Boom() })

        model.startDownload("whisper")   // a real, not-yet-installed catalog id
        await settleTasks()

        XCTAssertEqual(recorder.removed, ["whisper"])
        XCTAssertNotNil(try row("whisper", in: model).errorText)
        XCTAssertEqual(recorder.markedInstalled, [])   // never marked installed
    }

    func testFailedDownloadKeepsAlreadyInstalledModel() async throws {
        struct Boom: Error {}
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, download: { _, _ in throw Boom() })

        model.startDownload("parakeet")   // already in initialInstalledIds
        await settleTasks()

        XCTAssertEqual(recorder.removed, [])   // guarded: installed models are preserved
    }

    func testCancellingInactiveDeletionPreservesTheModel() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)
        model.requestDelete("parakeet")
        model.cancelDelete()
        await settleTasks()
        XCTAssertTrue(try row("parakeet", in: model).isUsable)
        XCTAssertTrue(recorder.removed.isEmpty)
        XCTAssertTrue(recorder.evicted.isEmpty)
    }

    func testPassingSelfTestEvictsAnInactiveEngine() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: .passed)

        // "parakeet" is installed but not the active engine ("parakeet-tdt-ctc-110m").
        model.test("parakeet")
        await settleTasks()

        XCTAssertEqual(recorder.evicted, ["parakeet"])
        XCTAssertTrue(try row("parakeet", in: model).testPassed)
        XCTAssertFalse(try row("parakeet", in: model).verificationFailed)
    }

    func testPassingSelfTestKeepsTheActiveEngineResident() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: .passed)

        model.test("parakeet-tdt-ctc-110m")   // the active engine
        await settleTasks()

        XCTAssertEqual(recorder.evicted, [])
    }

    // Files are kept (not removed) so the user can re-test cheaply or reinstall.
    func testFailedSelfTestQuarantinesButKeepsFiles() async throws {
        let recorder = Recorder()
        let model = makeModel(
            recorder: recorder,
            verifyResult: .failed,
            deferWhileBusy: { recorder.deferred.append($0) })

        model.test("parakeet")
        await settleTasks()

        XCTAssertEqual(recorder.markedFailed, ["parakeet"])
        XCTAssertEqual(recorder.evicted, ["parakeet"])
        XCTAssertEqual(recorder.removed, [])
        XCTAssertEqual(recorder.markedRemoved, [])
        XCTAssertFalse(try row("parakeet", in: model).isUsable)
        XCTAssertTrue(try row("parakeet", in: model).verificationFailed)
        XCTAssertNotNil(try row("parakeet", in: model).errorText)
    }

    func testFailingTheActiveModelHandsOffToAUsableEngine() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: .failed, activeId: "parakeet")

        model.test("parakeet")   // the active engine
        await settleTasks()

        XCTAssertEqual(recorder.markedFailed, ["parakeet"])
        XCTAssertFalse(recorder.activeChanges.isEmpty)
        XCTAssertNotEqual(recorder.activeChanges.last, "parakeet")
        XCTAssertFalse(try row("parakeet", in: model).isUsable)
    }

    func testPersistedFailureHydratesIntoRow() throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, initialFailedIds: ["parakeet"])

        XCTAssertTrue(try row("parakeet", in: model).verificationFailed)
        XCTAssertFalse(try row("parakeet", in: model).isUsable)
        XCTAssertNotNil(try row("parakeet", in: model).errorText)
    }

    // hasFailedModel feeds the Settings problem badge / menu-bar error dot.
    func testHasFailedModelHydratesFromPersistedFailure() {
        let recorder = Recorder()
        XCTAssertFalse(makeModel(recorder: recorder).hasFailedModel)
        XCTAssertTrue(makeModel(recorder: recorder, initialFailedIds: ["parakeet"]).hasFailedModel)
    }

    func testHasFailedModelFlipsLiveOnAFailingTest() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: .failed)
        XCTAssertFalse(model.hasFailedModel)

        model.test("parakeet")
        await settleTasks()

        XCTAssertTrue(model.hasFailedModel)
    }

    func testHasFailedModelClearsWhenTheOnlyFailurePasses() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: .passed, initialFailedIds: ["parakeet"])
        XCTAssertTrue(model.hasFailedModel)

        model.test("parakeet")
        await settleTasks()

        XCTAssertFalse(model.hasFailedModel)
    }

    func testPassingReTestClearsPersistedFailure() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: .passed, initialFailedIds: ["parakeet"])

        model.test("parakeet")
        await settleTasks()

        XCTAssertEqual(recorder.clearedFailed, ["parakeet"])
        XCTAssertTrue(try row("parakeet", in: model).isUsable)
        XCTAssertFalse(try row("parakeet", in: model).verificationFailed)
    }

    func testSkippedSelfTestKeepsAQuarantinedModelQuarantined() async throws {
        let recorder = Recorder()
        let model = makeModel(
            recorder: recorder, verifyResult: .skipped, initialFailedIds: ["parakeet"])

        model.test("parakeet")
        await settleTasks()

        XCTAssertTrue(try row("parakeet", in: model).verificationFailed)
        XCTAssertFalse(try row("parakeet", in: model).isUsable)
        XCTAssertEqual(recorder.clearedFailed, [])
        XCTAssertEqual(recorder.markedInstalled, [])
        XCTAssertNotNil(try row("parakeet", in: model).errorText)
    }

    // A skipped self-test means "the gate was busy", not "this model is broken". Quarantining it here
    // blamed a working model for losing a race with a dictation, and the row then stayed failed across
    // relaunch. It must stay retryable, and the engine the download just loaded must not stay resident.
    func testSkippedPostDownloadVerificationLeavesTheModelRetryableAndEvictsIt() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: .skipped)

        model.startDownload("whisper")
        await settleTasks()

        XCTAssertEqual(recorder.markedInstalled, [])
        XCTAssertEqual(recorder.markedFailed, [])
        XCTAssertFalse(try row("whisper", in: model).verificationFailed)
        XCTAssertEqual(recorder.evicted, ["whisper"])
        XCTAssertNotNil(try row("whisper", in: model).errorText)
    }

    // Eviction keys off usable STATE, not identity: activeId can still point at a quarantined model when
    // no replacement exists, and retaining that engine strands multiple GB.
    func testSkippedSelfTestKeepsTheActiveUsableEngineResident() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: .skipped, activeId: "parakeet")

        model.test("parakeet")
        await settleTasks()

        XCTAssertEqual(recorder.evicted, [])
    }

    func testSkippedSelfTestEvictsAnActiveButQuarantinedEngine() async throws {
        let recorder = Recorder()
        let model = makeModel(
            recorder: recorder, verifyResult: .skipped,
            activeId: "parakeet", initialFailedIds: ["parakeet"])

        model.test("parakeet")
        await settleTasks()

        XCTAssertEqual(recorder.evicted, ["parakeet"])
    }

    // Two large engines loading at once is several GB of avoidable concurrent residency, so only one
    // memory-heavy model operation runs at a time. Enforced in the model, not just by disabling buttons.
    func testASecondInstallIsRefusedWhileOneIsStillLoading() async throws {
        let recorder = Recorder()
        let gate = DownloadGate()
        // defer: an assertion throwing below would otherwise strand the waiting thread forever.
        defer { gate.release() }
        let model = makeModel(recorder: recorder, download: { _, _ in try await gate.hold() })

        model.startDownload("whisper")
        await settleTasks()
        model.startDownload("qwen3-asr-1.7b")
        await settleTasks()

        XCTAssertNotNil(try row("whisper", in: model).downloadFraction)
        XCTAssertNil(try row("qwen3-asr-1.7b", in: model).downloadFraction)
        XCTAssertNotNil(try row("qwen3-asr-1.7b", in: model).errorText)

        gate.release()
        await waitUntil({ (try? self.row("whisper", in: model).downloadFraction) == nil },
                        "the held download to unwind")
    }

    func testTheInstallGuardIsReleasedAfterAFailedDownload() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, download: { _, _ in throw Recorder.Failure() })

        model.startDownload("whisper")
        await settleTasks()
        model.startDownload("qwen3-asr-1.7b")
        await settleTasks()

        // Both attempts reached their partial-file cleanup, so the second one really started.
        XCTAssertEqual(recorder.removed, ["whisper", "qwen3-asr-1.7b"])
    }

    func testTheInstallGuardIsReleasedAfterVerification() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: .passed)

        model.startDownload("whisper")
        await settleTasks()
        model.startDownload("qwen3-asr-1.7b")
        await settleTasks()

        XCTAssertEqual(recorder.markedInstalled, ["whisper", "qwen3-asr-1.7b"])
    }

    // The marker write can fail after a PASS. That path returns early, so it has to hand the guard back or
    // every other model's install stays blocked until relaunch.
    func testTheInstallGuardIsReleasedWhenTheMarkerWriteFailsAfterAPass() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: .passed)
        recorder.markInstalledShouldFail = true

        model.startDownload("whisper")
        await settleTasks()
        recorder.markInstalledShouldFail = false
        model.startDownload("qwen3-asr-1.7b")
        await settleTasks()

        XCTAssertTrue(recorder.markedInstalled.contains("qwen3-asr-1.7b"))
    }

    // Delete evicts the engine and removes its weights, so it must not run against a model that is still
    // being verified — nor while another model holds the operation guard.
    func testDeleteIsRefusedWhileAnotherModelOperationHoldsTheGuard() async throws {
        let recorder = Recorder()
        let gate = DownloadGate()
        defer { gate.release() }
        let model = makeModel(recorder: recorder, download: { _, _ in try await gate.hold() })

        model.startDownload("whisper")
        await settleTasks()
        model.requestDelete("parakeet")
        model.confirmDelete()
        await settleTasks()

        XCTAssertEqual(recorder.removed, [])
        // Pins the "before" state so the wait below observes a real transition rather than passing vacuously.
        XCTAssertNotNil(try row("whisper", in: model).downloadFraction)

        gate.release()
        // Not `recorder.removed`: removeFiles completes BEFORE the task clears `downloading` and releases
        // the operation guard, so that condition can be true while the task is still unwinding.
        await waitUntil({ (try? self.row("whisper", in: model).downloadFraction) == nil },
                        "the held download to unwind")
    }

    // reinstall() deletes and then hands off to startDownload. It must carry the guard across that
    // internal transition, or it blocks its own follow-up download.
    func testReinstallRetainsTheGuardAcrossItsOwnDownloadHandoff() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: .passed)

        model.reinstall("parakeet")
        await settleTasks()

        XCTAssertEqual(recorder.removed, ["parakeet"])
        XCTAssertEqual(recorder.markedInstalled, ["parakeet"])
        XCTAssertNil(try row("parakeet", in: model).errorText)
    }

    func testFailedPostDownloadVerificationKeepsQuarantinedInstallRecoverable() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: .failed)

        model.startDownload("whisper")
        await settleTasks()

        XCTAssertEqual(recorder.markedInstalled, ["whisper"])
        XCTAssertTrue(try row("whisper", in: model).verificationFailed)
        XCTAssertFalse(try row("whisper", in: model).isUsable)
    }

    func testFailedDownloadReportsPartialFileCleanupFailure() async throws {
        struct Boom: Error {}
        let recorder = Recorder()
        recorder.removeShouldFail = true
        let model = makeModel(recorder: recorder, download: { _, _ in throw Boom() })

        model.startDownload("whisper")
        await settleTasks()

        XCTAssertEqual(
            try row("whisper", in: model).errorText,
            "Download failed, and partial model files couldn’t be removed. Try again.")
    }

    func testLateProgressAfterDownloadCompletionIsIgnored() async throws {
        final class ProgressBox: @unchecked Sendable {
            var callback: (@Sendable (ModelLoadProgress) -> Void)?
        }
        let recorder = Recorder()
        let progress = ProgressBox()
        let model = makeModel(
            recorder: recorder,
            verifyResult: .passed,
            download: { _, callback in progress.callback = callback })

        model.startDownload("whisper")
        await settleTasks()
        progress.callback?(ModelLoadProgress(phase: "Downloading…", fraction: 0.5))
        await settleTasks()

        XCTAssertNil(try row("whisper", in: model).downloadFraction)
        XCTAssertTrue(try row("whisper", in: model).isUsable)
    }

    func testPartialDeleteFailureQuarantinesModelAndKeepsItRetryable() async throws {
        let recorder = Recorder()
        recorder.removeShouldFail = true
        let model = makeModel(recorder: recorder)

        model.requestDelete("parakeet")
        model.confirmDelete()
        await settleTasks()

        XCTAssertFalse(try row("parakeet", in: model).isUsable)
        XCTAssertTrue(try row("parakeet", in: model).verificationFailed)
        XCTAssertNotNil(try row("parakeet", in: model).errorText)
        XCTAssertEqual(recorder.markedRemoved, ["parakeet"])
        XCTAssertEqual(recorder.markedInstalled, ["parakeet"])
        XCTAssertEqual(recorder.markedFailed, ["parakeet"])
        model.reinstall("parakeet")
        await settleTasks()
        XCTAssertEqual(recorder.removed, ["parakeet", "parakeet"])
    }

    func testMarkerFailureDoesNotReportDeletionAsSuccessful() async throws {
        let recorder = Recorder()
        recorder.markRemovedShouldFail = true
        let model = makeModel(recorder: recorder)

        model.requestDelete("parakeet")
        model.confirmDelete()
        await settleTasks()

        XCTAssertTrue(try row("parakeet", in: model).isUsable)
        XCTAssertNotNil(try row("parakeet", in: model).errorText)
        XCTAssertEqual(recorder.removed, [])
    }

    func testDeletingActiveModelBlocksNewDictationAdmission() async {
        let recorder = Recorder()
        let model = makeModel(
            recorder: recorder,
            activeId: "parakeet",
            deferWhileBusy: { recorder.deferred.append($0) })

        model.requestDelete("parakeet")
        model.confirmDelete()

        XCTAssertFalse(model.activeEngineUsable)
    }

    func testDeletingModelCannotBeSelectedBeforeIdleDeletionRuns() async throws {
        let recorder = Recorder()
        let model = makeModel(
            recorder: recorder,
            deferWhileBusy: { recorder.deferred.append($0) })

        model.requestDelete("parakeet")
        model.confirmDelete()
        model.select("parakeet")
        model.syncActive("parakeet")

        XCTAssertEqual(recorder.activeChanges, [])
        XCTAssertFalse(try row("parakeet", in: model).isActive)
    }

    func testQuarantinedAdoptedInstallCannotRunAfterRelaunch() {
        XCTAssertFalse(
            InstalledEngineFilter.shouldRun(
                engineId: "whisper", installedIds: ["whisper"], failedIds: ["whisper"]))
    }

    // The two list sections partition by residency (agent_notes/three_column_designs/option-1-rollout.md):
    // every usable model, including the always-usable system-managed Apple engine, is On This Mac;
    // everything else is Available to Download. Exhaustive and disjoint.
    func testRowsPartitionByResidency() {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder)

        let onMac = Set(model.onThisMacRows.map(\.id))
        XCTAssertTrue(onMac.contains("parakeet-tdt-ctc-110m"))
        XCTAssertTrue(onMac.contains("parakeet"))
        XCTAssertTrue(onMac.contains("apple"), "system-managed Apple engine is always On This Mac")
        XCTAssertTrue(model.onThisMacRows.allSatisfy(\.isUsable))
        XCTAssertTrue(model.availableRows.allSatisfy { !$0.isUsable })
        XCTAssertEqual(model.onThisMacRows.count + model.availableRows.count, model.rows.count)
        XCTAssertTrue(model.availableRows.contains { $0.id == "whisper" })
    }

    // A quarantined model keeps its maintenance recovery, so it is not treated as a pristine catalog preview.
    func testFailedModelStaysAvailableWithRecovery() {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, initialFailedIds: ["parakeet"])

        XCTAssertTrue(model.availableRows.contains { $0.id == "parakeet" })
        XCTAssertFalse(model.onThisMacRows.contains { $0.id == "parakeet" })
    }

    func testChoiceCopyExplainsTheRecommendedAndBuiltInOptions() {
        let recommended = SpeechModelCatalog.entry(for: "parakeet")!
        let builtIn = SpeechModelCatalog.entry(for: "apple")!

        XCTAssertEqual(
            SpeechModelChoiceCopy.bestFor(recommended),
            "Fast, accurate dictation for most people.")
        XCTAssertEqual(
            SpeechModelChoiceCopy.bestFor(builtIn),
            "No download and the fastest setup.")
        XCTAssertEqual(SpeechModelChoiceCopy.memoryUse(for: recommended), "Light memory use")
        XCTAssertEqual(
            SpeechModelChoiceCopy.memoryUse(for: SpeechModelCatalog.entry(for: "whisper")!),
            "High memory use")
    }

    func testChoiceActionUsesOneDirectActionPerModel() {
        XCTAssertEqual(
            SpeechModelChoiceCopy.primaryAction(
                isActive: true, isUsable: true, isDownloading: false,
                isVerifying: false, verificationFailed: false),
            .current)
        XCTAssertEqual(
            SpeechModelChoiceCopy.primaryAction(
                isActive: false, isUsable: true, isDownloading: false,
                isVerifying: false, verificationFailed: false),
            .use)
        XCTAssertEqual(
            SpeechModelChoiceCopy.primaryAction(
                isActive: false, isUsable: false, isDownloading: false,
                isVerifying: false, verificationFailed: false),
            .download)
    }
}
