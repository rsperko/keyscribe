import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

// The retention sweep runs on the first dictation of a day, then is skipped for same-day dictations —
// observed via an always-expired day file: a sweep deletes it, a skipped sweep leaves it.
@MainActor
struct HistoryRetentionSweepTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "hello" }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
    }

    private let expiredDay = "2000-01-01"

    private func expiredEntry() -> HistoryEntry {
        HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 946_684_800), modeName: "M", heard: "old",
            result: "old", outcome: .inserted, cloudInvolved: false, redaction: false, contextCategories: [])
    }

    private func makeController(supportDir: URL, history: HistoryStore) -> DictationController {
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        try? ModeStore.write(Mode(id: "m", name: "M"), to: modesDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(muteSystemAudio: false, keepDisplayAwake: false, sounds: false)

        let provider = try! SpeechEngineProvider(engines: [FixedEngine()], activeId: "fixed")
        return DictationController(
            settings: settings, provider: provider, config: ConfigCache(supportDir: supportDir),
            history: history, hud: nil,
            audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
            insert: { _, _, _, _, _ in true },
            submitKey: { _ in },
            snapshot: { TargetSnapshot(bundleId: "test.bundle") },
            micStatus: { .granted },
            accessibilityGranted: { true })
    }

    private func dictate(_ controller: DictationController) async {
        controller.setNextModeOverride(id: "m")
        controller.handleStart()
        await controller.captureBringUpTask?.value
        controller.handleCommit()
        await controller.dictationTask?.value
    }

    private func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    private func pollUntil(_ condition: () -> Bool, tries: Int = 60) async -> Bool {
        for _ in 0..<tries {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func firstDictationOfTheDaySweepsExpiredFiles() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let history = HistoryStore(supportDir: supportDir)
        try? history.append(expiredEntry(), today: expiredDay)
        let expiredFile = history.dir.appendingPathComponent("\(expiredDay).jsonl")
        #expect(exists(expiredFile))

        let controller = makeController(supportDir: supportDir, history: history)
        await dictate(controller)

        #expect(await pollUntil { !exists(expiredFile) })
    }

    @Test func secondSameDayDictationSkipsTheSweep() async {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let history = HistoryStore(supportDir: supportDir)
        try? history.append(expiredEntry(), today: expiredDay)
        let expiredFile = history.dir.appendingPathComponent("\(expiredDay).jsonl")

        let controller = makeController(supportDir: supportDir, history: history)
        await dictate(controller)
        #expect(await pollUntil { !exists(expiredFile) })

        try? history.append(expiredEntry(), today: expiredDay)
        #expect(exists(expiredFile))
        let todayFile = history.dir.appendingPathComponent("\(HistoryStore.todayString()).jsonl")
        let entriesBefore = history.entries().count
        await dictate(controller)
        #expect(await pollUntil { history.entries().count > entriesBefore })
        #expect(exists(todayFile))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(exists(expiredFile))
    }
}
