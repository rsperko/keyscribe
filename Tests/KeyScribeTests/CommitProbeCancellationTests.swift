import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct CommitProbeCancellationTests {
    private final class SequencedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        private let lock = NSLock()
        private var texts: [String]
        private var calls = 0
        init(_ texts: [String]) { self.texts = texts }
        var transcribed: Int { lock.withLock { calls } }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
            lock.withLock { calls += 1; return texts.isEmpty ? "" : texts.removeFirst() }
        }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    @MainActor private final class HeldProbe {
        var armed = false
        private var held: CheckedContinuation<Void, Never>?
        private var reached: CheckedContinuation<Void, Never>?
        private var isHeld = false

        func snapshot() async -> TargetSnapshot {
            guard armed else { return TargetSnapshot(bundleId: "test.bundle", pid: 100) }
            armed = false
            isHeld = true
            reached?.resume()
            reached = nil
            await withCheckedContinuation { held = $0 }
            return TargetSnapshot(bundleId: "test.bundle", pid: 100, isSecureField: true)
        }

        func waitUntilHeld() async {
            if isHeld { return }
            await withCheckedContinuation { reached = $0 }
        }

        func release() {
            held?.resume()
            held = nil
        }
    }

    private final class Inserted: @unchecked Sendable {
        var items: [(InsertionDecision, String)] = []
    }

    @Test func aCancelledTakeWaitingOnThePasswordProbeLeavesTheNextTakeAlone() async throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-probe-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: supportDir.appendingPathComponent("modes", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        let probe = HeldProbe()
        let inserted = Inserted()
        let engine = SequencedEngine(["first take", "second take"])
        let provider = try SpeechEngineProvider(engines: [engine], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: nil, permits: { _ in true },
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { decision, _, _, text, _ in inserted.items.append((decision, text)); return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 100) },
            snapshotAsync: { await probe.snapshot() },
            micStatus: { .granted },
            accessibilityGranted: { true })

        controller.handleStart()
        await controller.captureBringUpTask?.value
        await controller.snapshotAdoptionTask?.value
        probe.armed = true
        controller.handleCommit()
        let stale = try #require(controller.dictationTask)
        await probe.waitUntilHeld()
        while engine.transcribed == 0 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        controller.cancel()

        controller.handleStart()
        await controller.captureBringUpTask?.value
        await controller.snapshotAdoptionTask?.value
        probe.release()
        await stale.value
        #expect(inserted.items.isEmpty)

        controller.handleCommit()
        await controller.dictationTask?.value
        #expect(inserted.items.map { $0.1.trimmingCharacters(in: .whitespaces) } == ["second take"])
        #expect(inserted.items.first?.0 == .insert)
    }
}
