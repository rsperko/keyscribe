import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct IdleEvictionRescheduleTests {
    private final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var fired = false
        func wait() async {
            await withCheckedContinuation { c in
                lock.lock()
                if fired { lock.unlock(); c.resume(); return }
                continuation = c
                lock.unlock()
            }
        }
        func fire() {
            lock.lock()
            fired = true
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    private final class EvictSpyEngine: SpeechEngine, @unchecked Sendable {
        let id = "balanced-engine"
        let displayName = "Balanced"
        let supportsRecognitionBias = true
        private let text: String
        let evicted = Signal()
        private let lock = NSLock()
        private var _evictions = 0
        var evictions: Int { lock.withLock { _evictions } }
        init(text: String) { self.text = text }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { text }
        func evict() async {
            lock.withLock { _evictions += 1 }
            evicted.fire()
        }
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    @Test func shorteningTheIdleWindowEvictsWithoutWaitingForTheStaleTimer() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStarterFilesForTesting(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let engine = EvictSpyEngine(text: "hello world")
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "balanced-engine")
        var settings = Settings.defaults
        settings.stt = .init(engine: "balanced-engine", eviction: .balanced, evictionIdleSeconds: 3600)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value

        #expect(engine.evictions == 0)

        settings.stt.evictionIdleSeconds = 0
        controller.updateSettings(settings)

        let evicted = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await engine.evicted.wait(); return true }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(evicted)
    }

    @Test func switchingToFastestCancelsThePendingIdleEviction() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        ModeStore.seedStarterFilesForTesting(in: supportDir.appendingPathComponent("modes", isDirectory: true))

        let engine = EvictSpyEngine(text: "hello world")
        let provider = try! SpeechEngineProvider(engines: [engine], activeId: "balanced-engine")
        var settings = Settings.defaults
        settings.stt = .init(engine: "balanced-engine", eviction: .balanced, evictionIdleSeconds: 3600)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)
        let controller = DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: HistoryStore(supportDir: supportDir), hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in return true },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted }, accessibilityGranted: { true })

        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value

        settings.stt.eviction = .fastest
        controller.updateSettings(settings)

        try? await Task.sleep(for: .milliseconds(300))
        #expect(engine.evictions == 0)
    }
}
