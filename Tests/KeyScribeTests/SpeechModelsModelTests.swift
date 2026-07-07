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
        deferWhileBusy: ((@escaping () -> Void) -> Void)? = nil
    ) -> SpeechModelsModel {
        SpeechModelsModel(
            activeId: activeId,
            stt: Settings.defaults.stt,
            download: { _, _ in },
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
        await settleTasks()

        XCTAssertEqual(recorder.evicted, ["parakeet"])
        XCTAssertEqual(recorder.markedRemoved, ["parakeet"])
        XCTAssertEqual(recorder.removed, [])
        XCTAssertEqual(recorder.deferred.count, 1)
        XCTAssertFalse(try row("parakeet", in: model).isUsable)

        recorder.deferred[0]()

        XCTAssertEqual(recorder.removed, ["parakeet"])
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

    // A failed self-test quarantines the model: it becomes unusable and is persisted as failed, but its
    // files are kept (not removed) so the user can re-test cheaply or reinstall.
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

    // A persisted failure hydrates into the row on launch so the error indicator survives a restart.
    func testPersistedFailureHydratesIntoRow() throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, initialFailedIds: ["parakeet"])

        XCTAssertTrue(try row("parakeet", in: model).verificationFailed)
        XCTAssertFalse(try row("parakeet", in: model).isUsable)
        XCTAssertNotNil(try row("parakeet", in: model).errorText)
    }

    // hasFailedModel feeds the Settings problem badge / menu-bar error dot. It reflects any failed row —
    // hydrated from persisted state on launch, flipped live by a failing test, and cleared by a passing one.
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

    // Re-testing a quarantined model that now passes clears the persisted failure and restores usability.
    func testPassingReTestClearsPersistedFailure() async throws {
        let recorder = Recorder()
        let model = makeModel(recorder: recorder, verifyResult: true, initialFailedIds: ["parakeet"])

        model.test("parakeet")
        await settleTasks()

        XCTAssertEqual(recorder.clearedFailed, ["parakeet"])
        XCTAssertTrue(try row("parakeet", in: model).isUsable)
        XCTAssertFalse(try row("parakeet", in: model).verificationFailed)
    }
}
