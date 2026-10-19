import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandWiringTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        private let text: String
        init(text: String) { self.text = text }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { text }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var handler: (@Sendable () -> Void)?
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
        func setCaptureLostHandler(_ handler: @escaping @Sendable () -> Void) {
            lock.withLock { self.handler = handler }
        }
        func loseCapture() { lock.withLock { handler }?() }
    }

    private enum Loss { case none, beforeRelease, whileResolving }

    private final class HUDSpy: HUDPresenting {
        private(set) var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private final class RunnerSpy: VoiceCommandRunning {
        var outcome: VoiceCommandOutcome = .done(summary: "Ghostty", command: "Brings Ghostty to the front, opening it if needed.")
        var whileResolving: () -> Void = {}
        private(set) var calls: [(
            transcript: String, places: [VoiceCommandPlace], scripts: [VoiceCommandScript], origin: VoiceCommandOrigin?
        )] = []
        private(set) var lateResult: (@MainActor (VoiceCommandOutcome) -> Void)?
        func run(
            transcript: String, places: [VoiceCommandPlace], scripts: [VoiceCommandScript], origin: VoiceCommandOrigin?,
            stillWanted: @MainActor () -> Bool, onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void
        ) async -> VoiceCommandOutcome {
            calls.append((transcript, places, scripts, origin))
            lateResult = onLateResult
            whileResolving()
            return stillWanted() ? outcome : .abandoned
        }
    }

    private final class Captured: @unchecked Sendable {
        var insertedText: String?
    }

    private struct Run {
        let runner: RunnerSpy
        let hud: HUDSpy
        let inserted: String?
        let history: [HistoryEntry]
        let record: DictationRecord?
        var historyUpdates = 0
    }

    private func run(
        transcript: String, outcome: VoiceCommandOutcome = .done(summary: "Ghostty", command: "Brings Ghostty to the front, opening it if needed."),
        places: [VoiceCommandPlace] = [], scripts: [VoiceCommandScript] = [], otherModes: [Mode] = [], useVoiceCommands: Bool = true,
        flagOn: Bool = true, historyEnabled: Bool = true, secureField: Bool = false, focusMoves: Bool = false,
        loss: Loss = .none, late: VoiceCommandOutcome? = nil,
        vocabulary: (inout Mode) -> Void = { _ in }
    ) async throws -> Run {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-vcwire-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        var commands = Mode.voiceCommands
        commands.triggerKeys = [.init(key: "right_option")]
        vocabulary(&commands)
        try ModeStore.write(commands, to: modesDir)
        for mode in otherModes { try ModeStore.write(mode, to: modesDir) }
        try VoiceCommandStore.write(VoiceCommandConfig(places: places, scripts: scripts), to: supportDir)

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        settings.history = .init(enabled: historyEnabled, retentionDays: 7)
        settings.features.setEnabled(flagOn, for: .voiceCommands)

        let config = ConfigCache(supportDir: supportDir)
        config.voiceCommandsEnabled = true
        let history = HistoryStore(supportDir: supportDir)
        let hud = HUDSpy()
        let runner = RunnerSpy()
        runner.outcome = outcome
        let captured = Captured()
        let audio = FakeAudio(url: supportDir.appendingPathComponent("capture.wav"))
        if loss == .whileResolving { runner.whileResolving = { audio.loseCapture() } }
        let provider = try SpeechEngineProvider(engines: [FixedEngine(text: transcript)], activeId: "fixed")
        let controller = DictationController(
            settings: settings, provider: provider, config: config,
            history: history, hud: hud, permits: { _ in true },
            audio: audio,
            insert: { _, _, _, text, _ in captured.insertedText = text; return true },
            submitKey: { _ in },
            pressSnapshot: { TargetSnapshot(bundleId: "com.apple.TextEdit", pid: 1) },
            snapshot: { TargetSnapshot(bundleId: "com.apple.TextEdit", pid: 1, isSecureField: secureField) },
            snapshotAsync: {
                focusMoves ? TargetSnapshot(bundleId: "com.example.other", pid: 2)
                    : TargetSnapshot(bundleId: "com.apple.TextEdit", pid: 1, isSecureField: secureField)
            },
            micStatus: { .granted },
            accessibilityGranted: { true },
            voiceCommands: runner)

        controller.handleStart(triggerKey: useVoiceCommands ? "right_option" : nil)
        await controller.captureBringUpTask?.value
        await controller.snapshotAdoptionTask?.value
        if loss == .beforeRelease { audio.loseCapture() }
        controller.handleCommit()
        await controller.dictationTask?.value
        controller.waitForHistoryWrites()
        var historyUpdates = 0
        controller.onHistoryUpdated = { historyUpdates += 1 }
        if let late {
            runner.lateResult?(late)
            controller.waitForHistoryWrites()
            try await Task.sleep(for: .milliseconds(50))
        }
        return Run(runner: runner, hud: hud, inserted: captured.insertedText, history: history.entries(),
                   record: controller.lastRecord, historyUpdates: historyUpdates)
    }

    @Test func theCommandIsReadAfterTheModesOwnVocabularyCleansIt() async throws {
        let result = try await run(transcript: "Bitch to herder.") { mode in
            mode.dictionary.words = ["herdr"]
            mode.replacements.rules = [.init(heard: "bitch to", replace: "switch to", regex: false)]
        }
        #expect(result.runner.calls.map(\.transcript) == ["switch to herdr."])
    }

    @Test func aVoiceCommandRunsAndNothingIsInserted() async throws {
        let place = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"))
        let result = try await run(transcript: "Switch to Ghostty.", places: [place])
        #expect(result.runner.calls.map(\.transcript) == ["Switch to Ghostty."])
        #expect(result.runner.calls.first?.places == [place])
        #expect(result.runner.calls.first?.origin == VoiceCommandOrigin(bundleId: "com.apple.TextEdit"))
        #expect(result.inserted == nil)
        #expect(result.hud.states.last == .commandDone(summary: "Ghostty"))
    }

    @Test func aScriptStillRunningIsShownAndRecordedAsStarted() async throws {
        let result = try await run(
            transcript: "run deploy staging", outcome: .started(summary: "Deploy", command: "~/bin/deploy staging"))
        #expect(result.hud.states.last == .commandDone(summary: "Deploy", detail: HUDState.commandStillRunningDetail))
        let entry = try #require(result.history.first)
        #expect(entry.outcome == .commandStarted)
        #expect(entry.result == "~/bin/deploy staging")
        #expect(result.record?.outcome == .command)
    }

    @Test func aLateFailureUpdatesHistoryAndIsShown() async throws {
        let result = try await run(
            transcript: "run deploy staging", outcome: .started(summary: "Deploy", command: "~/bin/deploy staging"),
            late: .failed(message: "Deploy failed (exit 2): no such environment", command: "~/bin/deploy staging"))
        #expect(result.history.count == 1)
        let entry = try #require(result.history.first)
        #expect(entry.outcome == .commandFailed)
        #expect(entry.failureReason == "Deploy failed (exit 2): no such environment")
        #expect(entry.result == "~/bin/deploy staging")
        #expect(result.hud.states.last == .error(message: "Deploy failed (exit 2): no such environment", action: nil))
    }

    @Test func aLateResultTellsAnOpenHistoryToRefresh() async throws {
        let result = try await run(
            transcript: "run deploy staging", outcome: .started(summary: "Deploy", command: "~/bin/deploy staging"),
            late: .done(summary: "Deploy", command: "~/bin/deploy staging"))
        #expect(result.historyUpdates == 1)
    }

    @Test func aLateSuccessQuietlyCompletesTheHistoryEntry() async throws {
        let result = try await run(
            transcript: "run deploy staging", outcome: .started(summary: "Deploy", command: "~/bin/deploy staging"),
            late: .done(summary: "Deploy", command: "~/bin/deploy staging"))
        #expect(result.history.map(\.outcome) == [.command])
        #expect(result.hud.states.last == .commandDone(summary: "Deploy", detail: HUDState.commandStillRunningDetail))
    }

    @Test func aLateResultWithHistoryOffIsStillShown() async throws {
        let result = try await run(
            transcript: "run deploy staging", outcome: .started(summary: "Deploy", command: "~/bin/deploy staging"),
            historyEnabled: false, late: .failed(message: "Deploy failed (exit 1).", command: "~/bin/deploy staging"))
        #expect(result.history.isEmpty)
        #expect(result.hud.states.last == .error(message: "Deploy failed (exit 1).", action: nil))
    }

    @Test func aVoiceCommandIsRecordedWithTheCommandItRan() async throws {
        let result = try await run(transcript: "Bitch to Ghostty.") { mode in
            mode.replacements.rules = [.init(heard: "bitch to", replace: "switch to", regex: false)]
        }
        let entry = try #require(result.history.first)
        #expect(result.history.count == 1)
        #expect(entry.heard == "Bitch to Ghostty.")
        #expect(entry.transformed == "switch to Ghostty.")
        #expect(entry.result == "Brings Ghostty to the front, opening it if needed.")
        #expect(entry.outcome == .command)
        #expect(entry.failureReason == nil)
        #expect(entry.modeName == Mode.voiceCommands.name)
    }

    @Test func aFailedCommandIsRecordedWithWhyItFailed() async throws {
        let result = try await run(
            transcript: "deploy prod",
            outcome: .failed(message: "Deploy failed (exit 2): no such environment", command: "~/bin/deploy prod"))
        let entry = try #require(result.history.first)
        #expect(entry.result == "~/bin/deploy prod")
        #expect(entry.outcome == .commandFailed)
        #expect(entry.failureReason == "Deploy failed (exit 2): no such environment")
    }

    @Test func aCommandThatMatchedNothingIsRecordedWithNoCommand() async throws {
        let result = try await run(transcript: "switch to banana", outcome: .failed(message: "No app or place called “banana”."))
        let entry = try #require(result.history.first)
        #expect(entry.heard == "switch to banana")
        #expect(entry.result == "")
        #expect(entry.outcome == .commandFailed)
        #expect(entry.failureReason == "No app or place called “banana”.")
    }

    @Test func aCommandIsNotRecordedWhileHistoryIsOff() async throws {
        let result = try await run(transcript: "switch to ghostty", historyEnabled: false)
        #expect(result.runner.calls.count == 1)
        #expect(result.history.isEmpty)
    }

    @Test func aCommandSpokenIntoAPasswordFieldIsNotRecorded() async throws {
        let result = try await run(transcript: "deploy hunter2", secureField: true)
        #expect(result.runner.calls.count == 1)
        #expect(result.history.isEmpty)
    }

    @Test func aCommandWhoseTargetCouldNotBeConfirmedIsNotRecorded() async throws {
        let result = try await run(transcript: "deploy hunter2", focusMoves: true)
        #expect(result.runner.calls.count == 1)
        #expect(result.history.isEmpty)
        #expect(try await run(transcript: "deploy hunter2").history.count == 1)
    }

    @Test func aCommandModeExcludedFromHistoryRecordsNothing() async throws {
        let result = try await run(transcript: "switch to ghostty") { mode in mode.excludeFromHistory = true }
        #expect(result.runner.calls.count == 1)
        #expect(result.history.isEmpty)
    }

    @Test func theSavedScriptsReachTheRunner() async throws {
        let script = VoiceCommandScript(name: "Deploy", run: ["/usr/bin/true", "{text}"])
        let result = try await run(transcript: "run deploy staging", outcome: .done(summary: "Deploy", command: "/usr/bin/true staging"), scripts: [script])
        #expect(result.runner.calls.first?.scripts == [script])
        #expect(result.inserted == nil)
        #expect(result.history.map(\.result) == ["/usr/bin/true staging"])
        #expect(result.hud.states.last == .commandDone(summary: "Deploy"))
    }

    @Test func aFailedCommandShowsItsMessageAndInsertsNothing() async throws {
        let result = try await run(transcript: "switch to banana", outcome: .failed(message: "No app or place called “banana”."))
        #expect(result.inserted == nil)
        #expect(result.hud.states.last == .error(message: "No app or place called “banana”.", action: nil))
    }

    @Test func aSpokenSuffixNeverReroutesACommand() async throws {
        var email = Mode(id: "email", name: "Email")
        email.triggerPhrases = ["as an email"]
        let result = try await run(transcript: "switch to chrome as an email", otherModes: [email])
        #expect(result.runner.calls.map(\.transcript) == ["switch to chrome as an email"])
        #expect(result.inserted == nil)
    }

    @Test func anEmptyTranscriptRunsNoCommand() async throws {
        let result = try await run(transcript: "   ")
        #expect(result.runner.calls.isEmpty)
        #expect(result.inserted == nil)
    }

    @Test func aCommandModeDoesNothingWhileTheFlagIsOff() async throws {
        let result = try await run(transcript: "switch to chrome", flagOn: false)
        #expect(result.runner.calls.isEmpty)
        #expect(result.history.isEmpty)
        #expect(result.inserted == nil)
        #expect(result.hud.states.last == .error(message: "Voice commands are turned off.", action: nil))
    }

    @Test func aTakeWhoseMicrophoneDiedRunsNoCommand() async throws {
        let result = try await run(transcript: "switch to gmail", loss: .beforeRelease)
        #expect(result.runner.calls.isEmpty)
        #expect(result.inserted == nil)
        #expect(result.history.isEmpty)
        #expect(result.record?.outcome == .failed)
        #expect(result.hud.states.last == .error(message: "The microphone stopped, so the command did not run.", action: nil))
    }

    @Test func aMicrophoneLostWhileTheCommandResolvesStopsIt() async throws {
        let result = try await run(transcript: "switch to gmail", loss: .whileResolving)
        #expect(result.runner.calls.count == 1)
        #expect(result.inserted == nil)
        #expect(result.history.isEmpty)
        #expect(result.hud.states.last == .error(message: "The microphone stopped, so the command did not run.", action: nil))
    }

    @Test func ordinaryDictationNeverReachesTheRunner() async throws {
        let result = try await run(transcript: "switch to chrome", useVoiceCommands: false)
        #expect(result.runner.calls.isEmpty)
        #expect(result.inserted?.hasPrefix("switch to chrome") == true)
    }
}
