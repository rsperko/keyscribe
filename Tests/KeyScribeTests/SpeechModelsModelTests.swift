import XCTest
@testable import KeyScribe
import KeyScribeKit

@MainActor
final class SpeechModelsModelTests: XCTestCase {
    private final class Recorder {
        var deferred: [() -> Void] = []
        var evicted: [String] = []
        var removed: [String] = []
        var markedInstalled: [String] = []
        var markedRemoved: [String] = []
        var markedFailed: [String] = []
        var clearedFailed: [String] = []
        var activeChanges: [String] = []
    }

    private func makeModel(
        recorder: Recorder,
        verifyResult: Bool? = nil,
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
            removeFiles: { recorder.removed.append($0) },
            markInstalled: { recorder.markedInstalled.append($0) },
            markRemoved: { recorder.markedRemoved.append($0) },
            markFailed: { recorder.markedFailed.append($0) },
            clearFailed: { recorder.clearedFailed.append($0) })
    }

    private func settleTasks() async {
        for _ in 0..<5 { await Task.yield() }
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
        XCTAssertEqual(recorder.markedRemoved, ["parakeet"])
        XCTAssertEqual(recorder.removed, [])
        XCTAssertEqual(recorder.deferred.count, 1)
        XCTAssertFalse(try row("parakeet", in: model).isUsable)

        recorder.deferred[0]()

        XCTAssertEqual(recorder.removed, ["parakeet"])
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
        let model = makeModel(recorder: recorder, verifyResult: true)

        // "parakeet" is installed but not the active engine ("parakeet-tdt-ctc-110m").
        model.test("parakeet")
        await settleTasks()

        XCTAssertEqual(recorder.evicted, ["parakeet"])
        XCTAssertTrue(try row("parakeet", in: model).testPassed)
        XCTAssertFalse(try row("parakeet", in: model).verificationFailed)
    }

    func testPassingSelfTestKeepsTheActiveEngineResident() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: true)

        model.test("parakeet-tdt-ctc-110m")   // the active engine
        await settleTasks()

        XCTAssertEqual(recorder.evicted, [])
    }

    // Files are kept (not removed) so the user can re-test cheaply or reinstall.
    func testFailedSelfTestQuarantinesButKeepsFiles() async throws {
        let recorder = Recorder()
        let model = makeModel(
            recorder: recorder,
            verifyResult: false,
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
        let model = makeModel(recorder: recorder, verifyResult: false, activeId: "parakeet")

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
        let model = makeModel(recorder: recorder, verifyResult: false)
        XCTAssertFalse(model.hasFailedModel)

        model.test("parakeet")
        await settleTasks()

        XCTAssertTrue(model.hasFailedModel)
    }

    func testHasFailedModelClearsWhenTheOnlyFailurePasses() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: true, initialFailedIds: ["parakeet"])
        XCTAssertTrue(model.hasFailedModel)

        model.test("parakeet")
        await settleTasks()

        XCTAssertFalse(model.hasFailedModel)
    }

    func testPassingReTestClearsPersistedFailure() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: true, initialFailedIds: ["parakeet"])

        model.test("parakeet")
        await settleTasks()

        XCTAssertEqual(recorder.clearedFailed, ["parakeet"])
        XCTAssertTrue(try row("parakeet", in: model).isUsable)
        XCTAssertFalse(try row("parakeet", in: model).verificationFailed)
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
