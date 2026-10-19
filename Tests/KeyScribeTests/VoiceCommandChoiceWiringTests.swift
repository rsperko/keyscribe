import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandChoiceWiringTests {
    private final class ScriptedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        private let lock = NSLock()
        private var _text = ""
        var text: String {
            get { lock.withLock { _text } }
            set { lock.withLock { _text = newValue } }
        }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { text }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
        func setCaptureLostHandler(_ handler: @escaping @Sendable () -> Void) {}
    }

    private struct StubPresence: SpeechPresenceDetecting {
        func read(samples: [Float]?, url: URL, sampleRate: Int) async -> SpeechPresenceReading {
            SpeechPresenceReading(presence: .speech, peak: 0.5, latencyMs: 1, modelUsed: true, speechStart: nil)
        }
    }

    private final class HUDSpy: HUDPresenting {
        private(set) var states: [HUDState] = []
        var last: HUDState? { states.last }
        func render(_ state: HUDState) { states.append(state) }
    }

    private final class Captured: @unchecked Sendable {
        var inserted: [String] = []
        var clipboardReads = 0
    }

    final class ManualTimer: @unchecked Sendable {
        var now: Double = 100
        private var sleepers: [(until: Double, wake: CheckedContinuation<Void, Never>)] = []

        func sleep(_ seconds: Double) async {
            await withCheckedContinuation { sleepers.append((now + seconds, $0)) }
        }

        var pending: Int { sleepers.count }

        func advance(_ seconds: Double) {
            now += seconds
            let due = sleepers.filter { $0.until <= now }
            sleepers.removeAll { $0.until <= now }
            for sleeper in due { sleeper.wake.resume() }
        }
    }

    final class Gate: @unchecked Sendable {
        private var waiter: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        func wait() async {
            entered = true
            await withCheckedContinuation { waiter = $0 }
        }
        func open() { waiter?.resume(); waiter = nil }
    }

    @MainActor private final class Harness {
        let engine = ScriptedEngine()
        let hud = HUDSpy()
        let system = VoiceCommandRunnerTests.FakeSystem()
        let runner: VoiceCommandRunner
        let controller: DictationController
        let history: HistoryStore
        let config: ConfigCache
        let captured = Captured()
        let timer = ManualTimer()
        let supportDir: URL

        init(
            places: [VoiceCommandPlace], scripts: [VoiceCommandScript] = [], historyEnabled: Bool = true,
            titleScopedMode: Bool = false
        ) throws {
            supportDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("keyscribe-vcchoice-\(UUID().uuidString)", isDirectory: true)
            let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
            try FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
            var commands = Mode.voiceCommands
            commands.triggerKeys = [.init(key: "right_option")]
            try ModeStore.write(commands, to: modesDir)
            var email = Mode(id: "email", name: "Email")
            email.triggerKeys = [.init(key: "right_command")]
            try ModeStore.write(email, to: modesDir)
            if titleScopedMode {
                var inbox = Mode(id: "inbox", name: "Inbox")
                inbox.constraints = [Mode.Constraint(windowTitle: "Inbox")]
                try ModeStore.write(inbox, to: modesDir)
            }
            try VoiceCommandStore.write(VoiceCommandConfig(places: places, scripts: scripts), to: supportDir)

            var settings = Settings.defaults
            settings.stt = .init(engine: "fixed", eviction: .frugal)
            settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
            settings.history = .init(enabled: historyEnabled, retentionDays: 7)
            settings.features.setEnabled(true, for: .voiceCommands)

            config = ConfigCache(supportDir: supportDir)
            config.voiceCommandsEnabled = true
            history = HistoryStore(supportDir: supportDir)
            system.running = [
                VoiceCommandCatalog.App(name: "Safari", bundleId: "com.apple.Safari"),
                VoiceCommandCatalog.App(name: "Ghostty", bundleId: "com.mitchellh.ghostty"),
            ]
            let timer = timer
            runner = VoiceCommandRunner(system: system, now: { timer.now })
            let provider = try SpeechEngineProvider(engines: [engine], activeId: "fixed")
            let captured = captured
            controller = DictationController(
                settings: settings, provider: provider, config: config,
                history: history, hud: hud, permits: { _ in true },
                audio: FakeAudio(url: supportDir.appendingPathComponent("capture.wav")),
                presenceDetector: StubPresence(),
                insert: { _, _, _, text, _ in captured.inserted.append(text); return true },
                submitKey: { _ in },
                clipboard: { captured.clipboardReads += 1; return nil },
                pressSnapshot: { TargetSnapshot(bundleId: "com.apple.TextEdit", pid: 1) },
                snapshot: { TargetSnapshot(bundleId: "com.apple.TextEdit", pid: 1) },
                micStatus: { .granted },
                accessibilityGranted: { true },
                voiceCommands: runner)
            controller.choiceExpirySleep = { await timer.sleep($0) }
        }

        func press(_ trigger: String = "right_option") async {
            controller.handleStart(triggerKey: trigger)
            await controller.captureBringUpTask?.value
            await controller.snapshotAdoptionTask?.value
        }

        func dictate(_ text: String, trigger: String = "right_option") async {
            engine.text = text
            await press(trigger)
            controller.handleCommit()
            await controller.dictationTask?.value
            controller.waitForHistoryWrites()
        }

        func waitForSleepers(_ count: Int) async {
            for _ in 0..<500 where timer.pending < count { await Task.yield() }
        }

        func settle() async throws {
            for _ in 0..<20 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(30))
            controller.waitForHistoryWrites()
        }

        var prompt: VoiceCommandChoicePrompt? { controller.pendingVoiceCommandChoice }

        deinit { try? FileManager.default.removeItem(at: supportDir) }
    }

    private let personal = VoiceCommandPlace(
        name: "Personal Mail", say: ["mail"], target: .url("https://mail.example.net/"), browser: "com.apple.Safari")
    private let work = VoiceCommandPlace(
        name: "Work Mail", say: ["mail"], target: .url("https://inbox.example.org/"), browser: "com.apple.Safari")

    private func waiting(_ state: HUDState?) -> VoiceCommandChoicePrompt? {
        if case .choice(let prompt, .waiting, _) = state { return prompt }
        return nil
    }

    @Test func anAmbiguousCommandShowsANumberedQuestionThatDoesNotTakeFocus() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        let prompt = try #require(waiting(h.hud.last))
        #expect(prompt.title == "Which one?")
        #expect(prompt.rows.map(\.name) == ["Personal Mail", "Work Mail"])
        #expect(prompt.hint.hasPrefix("Use Right-\u{2325} and say"))
        #expect(h.hud.last?.holdsKeyFocus == false)
        #expect(h.hud.last?.isWaitingForChoice == true)
        #expect(h.captured.inserted.isEmpty)
        #expect(h.captured.clipboardReads == 0)
        #expect(h.history.entries().map(\.outcome) == [.commandNeedsChoice])
    }

    @Test func answeringKeepsTheListVisibleWhileRecordingAndTranscribing() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        let prompt = try #require(h.prompt)
        let shownBefore = h.hud.states.count
        await h.dictate("two")
        let answering = h.hud.states.dropFirst(shownBefore)
        #expect(!answering.contains(.hidden))
        #expect(answering.contains { if case .choice(prompt, .listening, _) = $0 { return true }; return false })
        #expect(answering.contains(.choice(prompt, status: .working)))
        #expect(answering.allSatisfy {
            if case .recording = $0 { return false }
            if case .transcribing = $0 { return false }
            return true
        })
        #expect(h.system.openedURLs.map(\.0) == ["https://inbox.example.org/"])
        #expect(h.hud.last == .commandDone(summary: "Work Mail"))
        #expect(h.prompt == nil)
    }

    @Test func historyRecordsTheQuestionAndAnUnderstandableAnswer() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        await h.dictate("two")
        let entries = h.history.entries()
        #expect(entries.map(\.outcome) == [.command, .commandNeedsChoice])
        let answer = try #require(entries.first)
        let question = try #require(entries.last)
        #expect(answer.heard == "two")
        #expect(answer.result.hasPrefix("Selected Work Mail for \u{201C}switch to mail\u{201D}: "))
        #expect(question.result == "Asked to choose: 1. Personal Mail, 2. Work Mail")
    }

    @Test func anInvalidReplyKeepsTheListAndSaysHowToAnswer() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        await h.dictate("seven")
        let prompt = try #require(waiting(h.hud.last))
        #expect(h.hud.last == .choice(prompt, status: .waiting(
            note: "Choose 1\u{2013}2, say \u{201C}cancel\u{201D}, or give a new command.")))
        #expect(h.history.entries().first?.outcome == .commandNeedsChoice)
        await h.dictate("1")
        #expect(h.system.openedURLs.map(\.0) == ["https://mail.example.net/"])
    }

    @Test func silenceLeavesTheQuestionInPlace() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        await h.dictate("   ")
        #expect(waiting(h.hud.last) != nil)
        #expect(h.prompt != nil)
        await h.dictate("second")
        #expect(h.system.openedURLs.map(\.0) == ["https://inbox.example.org/"])
    }

    @Test func cancellingTheAnswerRecordingKeepsTheQuestion() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        await h.press()
        h.controller.cancel()
        #expect(waiting(h.hud.last) != nil)
        #expect(h.prompt != nil)
    }

    @Test func spokenCancelDismissesNeutrally() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        await h.dictate("cancel")
        #expect(h.hud.last == .hidden)
        #expect(h.prompt == nil)
        #expect(h.history.entries().first?.outcome == .commandCancelled)
        await h.dictate("two")
        #expect(h.system.openedURLs.isEmpty)
    }

    @Test func startingAnotherModeDismissesTheQuestionAtStart() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        await h.press("right_command")
        #expect(h.prompt == nil)
        h.controller.cancel()
        await h.dictate("two")
        #expect(h.system.openedURLs.isEmpty)
    }

    @Test func switchingToAnotherAppDismissesButTheOriginalAppDoesNot() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        h.controller.noteAppActivated(bundleId: "com.apple.TextEdit")
        #expect(h.prompt != nil)
        h.controller.noteAppActivated(bundleId: "com.apple.Notes")
        #expect(h.prompt == nil)
        #expect(h.hud.last == .hidden)
    }

    @Test func lockingTheScreenOrEditingVoiceCommandsDismisses() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        h.controller.handleScreenLocked()
        #expect(h.prompt == nil)

        await h.dictate("switch to mail")
        h.controller.voiceCommandConfigurationChanged()
        #expect(h.prompt != nil)
        try VoiceCommandStore.write(VoiceCommandConfig(places: [personal]), to: h.supportDir)
        h.config.invalidate()
        h.controller.voiceCommandConfigurationChanged()
        #expect(h.prompt == nil)
    }

    @Test func theIdleTimeoutHidesOnlyItsOwnQuestion() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        await h.waitForSleepers(1)
        h.timer.advance(29)
        try await h.settle()
        #expect(h.prompt != nil)
        h.timer.advance(1)
        try await h.settle()
        #expect(h.prompt == nil)
        #expect(h.hud.last == .hidden)
        let hiddenCount = h.hud.states.count
        await h.dictate("two")
        #expect(h.system.openedURLs.isEmpty)
        #expect(!h.hud.states.dropFirst(hiddenCount).contains { $0.isWaitingForChoice })
    }

    @Test func aStaleTimerCannotHideANewerQuestion() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        await h.waitForSleepers(1)
        h.timer.advance(20)
        try await h.settle()
        await h.waitForSleepers(1)
        await h.dictate("seven")
        await h.waitForSleepers(2)
        h.timer.advance(20)
        try await h.settle()
        #expect(h.prompt != nil)
        #expect(waiting(h.hud.last) != nil)
        h.timer.advance(10)
        try await h.settle()
        #expect(h.prompt == nil)
    }

    @Test func theListStaysWhileTheModeIsStillBeingWorkedOut() async throws {
        let h = try Harness(places: [personal, work], titleScopedMode: true)
        await h.dictate("switch to mail")
        let shownBefore = h.hud.states.count
        await h.dictate("two")
        let answering = h.hud.states.dropFirst(shownBefore)
        #expect(answering.contains { if case .choice(_, .listening, _) = $0 { return true }; return false })
        #expect(answering.allSatisfy {
            if case .recording = $0 { return false }
            if case .transcribing = $0 { return false }
            return $0 != .hidden
        })
        #expect(h.system.openedURLs.map(\.0) == ["https://inbox.example.org/"])
    }

    @Test func aChosenActionThatIsStillRunningUpdatesItsAnswerWhenItFinishes() async throws {
        let deploy = VoiceCommandScript(name: "Deploy", say: ["ship"], run: ["/bin/deploy", "{text}"])
        let notify = VoiceCommandScript(name: "Notify", say: ["ship"], run: ["/bin/notify", "{text}"])
        let h = try Harness(places: [], scripts: [deploy, notify])
        h.system.scriptResult = .stillRunning
        await h.dictate("run ship staging")
        #expect(h.prompt?.title == "Which action?")
        await h.dictate("two")
        let started = try #require(h.history.entries().first)
        #expect(started.outcome == .commandStarted)
        #expect(started.result.hasPrefix("Selected Notify for \u{201C}run ship staging\u{201D}: "))
        #expect(h.system.scriptRuns.map(\.arguments) == [["staging"]])
        h.system.finishLate?(.finished(status: 1, lastError: "boom"))
        try await h.settle()
        let finished = try #require(h.history.entries().first)
        #expect(finished.outcome == .commandFailed)
        #expect(finished.id == started.id)
        #expect(finished.result == started.result)
    }

    @Test func aClickedRowThatIsStillLookingUpTabsIsDroppedWhenANewDictationStarts() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        let prompt = try #require(h.prompt)
        let gate = Gate()
        h.system.whileReadingTabs = { await gate.wait() }
        h.controller.chooseVoiceCommand(choice: prompt.id, candidate: prompt.rows[1].identity)
        for _ in 0..<50 where !gate.entered { await Task.yield() }
        #expect(gate.entered)
        h.engine.text = "hello"
        await h.press("right_command")
        gate.open()
        try await h.settle()
        #expect(h.system.openedURLs.isEmpty)
        #expect(!h.hud.states.contains(.commandDone(summary: "Work Mail")))
        h.controller.cancel()
    }

    enum ClickStop: CaseIterable, Sendable { case voiceCommandsTurnedOff, screenLocked, systemSleeping }

    @Test(arguments: ClickStop.allCases)
    func aClickedRowThatIsStillLookingUpTabsStopsWhenVoiceCommandsCanNoLongerRun(_ stop: ClickStop) async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        let prompt = try #require(h.prompt)
        let gate = Gate()
        h.system.whileReadingTabs = { await gate.wait() }
        h.controller.chooseVoiceCommand(choice: prompt.id, candidate: prompt.rows[1].identity)
        for _ in 0..<50 where !gate.entered { await Task.yield() }
        #expect(gate.entered)
        switch stop {
        case .voiceCommandsTurnedOff:
            var settings = Settings.defaults
            settings.stt = .init(engine: "fixed", eviction: .frugal)
            h.controller.updateSettings(settings)
        case .screenLocked:
            h.controller.handleScreenLocked()
        case .systemSleeping:
            h.controller.handleSystemSleep()
        }
        gate.open()
        try await h.settle()
        #expect(h.system.openedURLs.isEmpty)
        #expect(!h.hud.states.contains(.commandDone(summary: "Work Mail")))
    }

    @Test func aChoiceThatCannotBeClaimedIsClosedInTheRunnerToo() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        _ = try #require(h.runner.claimChoice())
        await h.press()
        #expect(h.runner.pendingChoice == nil)
        #expect(h.prompt == nil)
        h.controller.cancel()
    }

    @Test func clickingARowRunsItAndCompletesTheQuestionInHistory() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        let prompt = try #require(h.prompt)
        h.controller.chooseVoiceCommand(choice: prompt.id, candidate: prompt.rows[1].identity)
        try await h.settle()
        #expect(h.system.openedURLs.map(\.0) == ["https://inbox.example.org/"])
        #expect(h.hud.last == .commandDone(summary: "Work Mail"))
        let entries = h.history.entries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.outcome == .command)
        #expect(entry.result.hasPrefix("Selected Work Mail for \u{201C}switch to mail\u{201D}: "))
        h.controller.chooseVoiceCommand(choice: prompt.id, candidate: prompt.rows[0].identity)
        try await h.settle()
        #expect(h.system.openedURLs.count == 1)
    }

    @Test func clickingDuringAnAnswerRunsOnlyTheClickedRow() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        let prompt = try #require(h.prompt)
        h.engine.text = "two"
        await h.press()
        h.controller.handleCommit()
        h.controller.chooseVoiceCommand(choice: prompt.id, candidate: prompt.rows[0].identity)
        await h.controller.dictationTask?.value
        try await h.settle()
        #expect(h.system.openedURLs.map(\.0) == ["https://mail.example.net/"])
        #expect(h.hud.last == .commandDone(summary: "Personal Mail"))
    }

    @Test func theCancelButtonDismissesAndMarksTheQuestion() async throws {
        let h = try Harness(places: [personal, work])
        await h.dictate("switch to mail")
        let prompt = try #require(h.prompt)
        h.controller.cancelVoiceCommandChoice(choice: prompt.id)
        try await h.settle()
        #expect(h.prompt == nil)
        #expect(h.hud.last == .hidden)
        #expect(h.history.entries().map(\.outcome) == [.commandCancelled])
    }

    @Test func historyOffStillAsksButWritesNothing() async throws {
        let h = try Harness(places: [personal, work], historyEnabled: false)
        await h.dictate("switch to mail")
        await h.dictate("two")
        #expect(h.history.entries().isEmpty)
        #expect(h.system.openedURLs.count == 1)
    }

    @Test func goBackReturnsToTheAppOfTheOriginalCommand() async throws {
        let h = try Harness(places: [personal, work])
        h.system.running.append(VoiceCommandCatalog.App(name: "TextEdit", bundleId: "com.apple.TextEdit"))
        await h.dictate("switch to mail")
        await h.dictate("two")
        #expect(h.runner.backTarget == VoiceCommandOrigin(bundleId: "com.apple.TextEdit"))
    }
}
