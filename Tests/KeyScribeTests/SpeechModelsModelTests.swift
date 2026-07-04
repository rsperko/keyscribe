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
        var activeChanges: [String] = []
    }

    private func makeModel(
        recorder: Recorder,
        verifyResult: Bool? = nil,
        deferWhileBusy: ((@escaping () -> Void) -> Void)? = nil
    ) -> SpeechModelsModel {
        SpeechModelsModel(
            activeId: "parakeet-tdt-ctc-110m",
            stt: Settings.defaults.stt,
            download: { _, _ in },
            verify: { _ in verifyResult },
            evictEngine: { id in recorder.evicted.append(id) },
            onActiveChange: { recorder.activeChanges.append($0) },
            onDictionaryMatchingChange: { _ in },
            deferWhileBusy: deferWhileBusy ?? { $0() },
            initialInstalledIds: ["parakeet-tdt-ctc-110m", "parakeet"],
            removeFiles: { recorder.removed.append($0) },
            markInstalled: { recorder.markedInstalled.append($0) },
            markRemoved: { recorder.markedRemoved.append($0) })
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

    func testFailedSelfTestRemovesFilesImmediately() async throws {
        let recorder = Recorder()
        let model = makeModel(
            recorder: recorder,
            verifyResult: false,
            deferWhileBusy: { recorder.deferred.append($0) })

        model.test("parakeet")
        await settleTasks()

        XCTAssertEqual(recorder.evicted, ["parakeet"])
        XCTAssertEqual(recorder.removed, ["parakeet"])
        XCTAssertEqual(recorder.markedRemoved, ["parakeet"])
        XCTAssertEqual(recorder.deferred.count, 0)
        XCTAssertFalse(try row("parakeet", in: model).isUsable)
        XCTAssertTrue(try row("parakeet", in: model).verificationFailed)
    }
}
