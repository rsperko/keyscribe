import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct ClipboardPrefetchWiringTests {
    @MainActor private final class Events {
        var items: [String] = []
    }

    private final class HeldEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        let onReturn: @Sendable () async -> Void
        private let lock = NSLock()
        private var held: CheckedContinuation<Void, Never>?
        private var holds: Bool
        private var entered = false
        init(holds: Bool = false, onReturn: @escaping @Sendable () async -> Void = {}) {
            self.holds = holds
            self.onReturn = onReturn
        }
        var isInside: Bool { lock.withLock { entered } }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
            lock.withLock { entered = true }
            if lock.withLock({ holds }) {
                await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
            } else {
                try await Task.sleep(for: .milliseconds(100))
            }
            await onReturn()
            return "hello there"
        }
        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                holds = false
                let pending = held
                held = nil
                return pending
            }
            continuation?.resume()
        }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    private func controller(engine: HeldEngine, events: Events, dir: URL) throws -> DictationController {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("modes", isDirectory: true), withIntermediateDirectories: true)
        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        let provider = try SpeechEngineProvider(engines: [engine], activeId: "fixed")
        return DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: dir),
            history: HistoryStore(supportDir: dir), hud: nil, permits: { _ in true },
            audio: FakeAudio(url: dir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in await MainActor.run { events.items.append("insert") }; return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle", pid: 100) },
            micStatus: { .granted },
            accessibilityGranted: { true },
            prefetchClipboard: { events.items.append("prefetch") },
            discardPrefetchedClipboard: { events.items.append("discard") })
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-prefetch-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func theClipboardIsSnapshottedWhileTheEngineTranscribesAndBeforeTheInsert() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = Events()
        let engine = HeldEngine { await MainActor.run { events.items.append("transcribed") } }
        let controller = try controller(engine: engine, events: events, dir: dir)

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
        #expect(events.items == ["prefetch", "transcribed", "insert", "discard"])
    }

    @Test func cancellingDuringTranscriptionDiscardsTheSnapshot() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = Events()
        let engine = HeldEngine(holds: true)
        let controller = try controller(engine: engine, events: events, dir: dir)

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        for _ in 0..<100 where !engine.isInside { try await Task.sleep(for: .milliseconds(5)) }
        try #require(engine.isInside)
        await Task.yield()
        controller.cancel()
        #expect(events.items == ["prefetch", "discard"])
        engine.release()
        await controller.dictationTask?.value
        #expect(events.items == ["prefetch", "discard"])
    }

    @Test func aPrefetchWhoseTakeEndedBeforeItRanDoesNothing() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let events = Events()
        let controller = try controller(engine: HeldEngine(), events: events, dir: dir)

        controller.handleStart()
        await controller.captureBringUpTask?.value
        let prefetch = try #require(controller.startClipboardPrefetch())
        controller.cancel()
        await prefetch.value
        #expect(!events.items.contains("prefetch"))
    }
}
