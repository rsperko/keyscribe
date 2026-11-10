import AVFoundation
import KeyScribeKit
import Foundation

@MainActor
protocol SpeechSynthesizing: AnyObject {
    var onStarted: (() -> Void)? { get set }
    var onFinished: (() -> Void)? { get set }
    var isSpeaking: Bool { get }
    func speak(_ text: String, voice: String?)
    func stop()
    var attempt: String? { get }
    var reader: SpokenAttempt.Reader? { get }
    var macOSReason: String? { get }
}

extension SpeechSynthesizing {
    var attempt: String? { nil }
    var reader: SpokenAttempt.Reader? { nil }
    var macOSReason: String? { nil }
}

@MainActor
final class SystemSpeech: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    var onStarted: (() -> Void)?
    var onFinished: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { current != nil }

    func speak(_ text: String, voice: String?) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        if let voice, let chosen = AVSpeechSynthesisVoice(identifier: voice) { utterance.voice = chosen }
        current = utterance
        synthesizer.speak(utterance)
    }

    func stop() {
        guard current != nil else { return }
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        onFinished?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let started = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.current, ObjectIdentifier(current) == started else { return }
            self.onStarted?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finished = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(finished) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let cancelled = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(cancelled) }
    }

    private func ended(_ utterance: ObjectIdentifier) {
        guard let current, ObjectIdentifier(current) == utterance else { return }
        self.current = nil
        onFinished?()
    }
}

@MainActor
final class SpeechSilencer {
    static let shared = SpeechSilencer()

    private final class Entry {
        weak var speech: (any SpeechSynthesizing)?
        init(_ speech: any SpeechSynthesizing) { self.speech = speech }
    }

    private var entries: [Entry] = []
    private weak var owner: (any SpeechSynthesizing)?
    private var claiming = false
    private var dictationHUDVisible = false
    var onAvailable: (() -> Void)?
    private(set) var isRecording = false

    func register(_ speech: any SpeechSynthesizing) {
        entries = entries.filter { $0.speech != nil }
        entries.append(Entry(speech))
    }

    func registered<S: SpeechSynthesizing>(_ speech: S) -> S {
        register(speech)
        return speech
    }

    func speak(_ text: String, voice: String?, with speech: any SpeechSynthesizing) {
        guard !isRecording else { return }
        owner = speech
        claiming = true
        entries = entries.filter { $0.speech != nil }
        for entry in entries where entry.speech !== speech { entry.speech?.stop() }
        claiming = false
        speech.speak(text, voice: voice)
    }

    func isAvailable(for speech: any SpeechSynthesizing) -> Bool {
        guard !isRecording, !claiming, !dictationHUDVisible else { return false }
        guard let owner, owner !== speech else { return true }
        return !owner.isSpeaking
    }

    func dictationHUD(visible: Bool) {
        guard visible != dictationHUDVisible else { return }
        dictationHUDVisible = visible
        if !visible {
            onAvailable?()
            return
        }
        entries = entries.filter { $0.speech != nil }
        for entry in entries { entry.speech?.stop() }
    }

    func released(_ speech: any SpeechSynthesizing) {
        if owner === speech { owner = nil }
        onAvailable?()
    }

    func recordingStarted() {
        isRecording = true
        entries = entries.filter { $0.speech != nil }
        for entry in entries { entry.speech?.stop() }
    }

    func recordingEnded() {
        guard isRecording else { return }
        isRecording = false
        onAvailable?()
    }
}

@MainActor
protocol AudioPlaying: AnyObject {
    var onFinished: (() -> Void)? { get set }
    var isPlaying: Bool { get }
    var lastPlaybackFailed: Bool { get }
    func play(_ audio: Data) -> Bool
    func stop()
}

@MainActor
final class WAVPlayer: NSObject, AudioPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinished: (() -> Void)?
    private(set) var lastPlaybackFailed = false

    var isPlaying: Bool { player?.isPlaying ?? false }
    var current: AVAudioPlayer? { player }

    func play(_ audio: Data) -> Bool {
        stop()
        lastPlaybackFailed = false
        guard let player = try? AVAudioPlayer(data: audio) else { return false }
        self.player = player
        player.delegate = self
        return player.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in self.ended(finished, failed: !flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let failed = ObjectIdentifier(player)
        Task { @MainActor in
            Log.agents.error("natural voice playback failed to decode")
            self.ended(failed, failed: true)
        }
    }

    private func ended(_ finished: ObjectIdentifier, failed: Bool) {
        guard let current = player, ObjectIdentifier(current) == finished else { return }
        lastPlaybackFailed = failed
        current.stop()
        player = nil
        onFinished?()
    }
}

@MainActor
final class NaturalSpeech: SpeechSynthesizing {
    private enum Source { case making, player, fallback }

    private let ready: () -> Bool
    private let synthesize: @Sendable (String, String) async throws -> SpokenAudio
    private let player: any AudioPlaying
    private let fallback: any SpeechSynthesizing
    private let outcome: (_ natural: Bool, _ reason: String?, _ attempt: String?) -> Void
    private let fallbackLimit: (String) -> Duration
    private let synthesisLimit: (String) -> Duration
    private let unfinished = UnfinishedSyntheses()
    private var making: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var active: Source?
    private let attempts: SpokenAttempts?
    private let details: @Sendable (Bool) -> [SpokenAttempt.Detail]
    private let busyWait: Duration
    private(set) var attempt: String?
    private(set) var macOSReason: String?
    var onStarted: (() -> Void)?
    var onFinished: (() -> Void)?

    init(
        ready: @escaping () -> Bool, synthesize: @escaping @Sendable (String, String) async throws -> SpokenAudio,
        player: any AudioPlaying = WAVPlayer(), fallback: any SpeechSynthesizing = SystemSpeech(),
        outcome: @escaping (_ natural: Bool, _ reason: String?, _ attempt: String?) -> Void = { _, _, _ in },
        fallbackLimit: @escaping (String) -> Duration = NaturalSpeech.fallbackLimit,
        synthesisLimit: @escaping (String) -> Duration = NaturalSpeech.fallbackLimit,
        attempts: SpokenAttempts? = nil, busyWait: Duration = NaturalSpeech.busyWait,
        details: @escaping @Sendable (Bool) -> [SpokenAttempt.Detail] = SpokenAttempts.environment
    ) {
        self.attempts = attempts
        self.busyWait = busyWait
        self.details = details
        self.ready = ready
        self.synthesize = synthesize
        self.player = player
        self.fallback = fallback
        self.outcome = outcome
        self.fallbackLimit = fallbackLimit
        self.synthesisLimit = synthesisLimit
        player.onFinished = { [weak self] in
            guard let self, self.active == .player else { return }
            self.record { $0.playback = self.player.lastPlaybackFailed ? .failed : .finished }
            self.attempts?.ended(self.attempt)
            self.ended(.player)
        }
        fallback.onStarted = { [weak self] in
            guard let self, self.active == .fallback else { return }
            self.record { $0.playback = .playing }
            self.onStarted?()
        }
        fallback.onFinished = { [weak self] in
            guard let self, self.active == .fallback else { return }
            self.record { $0.playback = .finished }
            self.attempts?.ended(self.attempt)
            self.ended(.fallback)
        }
    }

    var isSpeaking: Bool { active != nil }
    var reader: SpokenAttempt.Reader? {
        switch active {
        case .player: .natural
        case .fallback: .macOS
        case .making, nil: nil
        }
    }
    var unfinishedSyntheses: Int { unfinished.count }

    private static let unfinishedLimit = 2
    static let busyWait: Duration = .seconds(2)

    nonisolated private static func waitingWhileBusy<T: Sendable>(
        upTo wait: Duration, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now + wait
        while true {
            do {
                return try await work()
            } catch is WorkBusy where clock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    nonisolated static func fallbackLimit(_ text: String) -> Duration {
        .seconds(10) + .milliseconds(600 * text.split(whereSeparator: { $0.isWhitespace }).count)
    }

    func speak(_ text: String, voice: String?) {
        silence()
        let voice = SpokenVoices.resolved(voice)
        macOSReason = nil
        attempt = attempts?.begin(text: text, voice: voice)
        if unfinished.count > 0 { record { $0.notes.append("Started while an earlier synthesis was still finishing.") } }
        guard ready() else { return speakWithFallback(text, because: "the natural voice isn\u{2019}t installed") }
        guard unfinished.count < Self.unfinishedLimit else {
            return speakWithFallback(text, because: "the natural voice was still finishing earlier replies")
        }
        let synthesize = synthesize
        let unfinished = unfinished
        let limit = synthesisLimit(text)
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        active = .making
        unfinished.begin()
        var task: Task<Void, Never>?
        let busyWait = busyWait
        let details = details
        task = Task { [weak self] in
            let made: Result<(SpokenAudio, [SpokenAttempt.Detail]), any Error>
            do {
                made = .success(try await runWithDeadline(
                    seconds: seconds,
                    operation: {
                        let audio = try await Self.waitingWhileBusy(upTo: busyWait) { try await synthesize(text, voice) }
                        return (audio, details(true))
                    },
                    onSettled: { unfinished.end() }))
            } catch {
                made = .failure(error)
            }
            guard !Task.isCancelled, let self, self.making == task else { return }
            self.making = nil
            var reason = Self.reason(for: made.map(\.0))
            if case .success(let (audio, details)) = made {
                self.record {
                    $0.audio = audio.wav
                    $0.synthesis = audio.synthesis
                    $0.details = details
                }
                self.active = .player
                if self.player.play(audio.wav) {
                    self.record {
                        $0.reader = .natural
                        $0.playback = .playing
                    }
                    self.outcome(true, nil, self.attempt)
                    self.onStarted?()
                    return
                }
                reason = "the audio couldn\u{2019}t be played"
            } else if case .failure(let error as SpokenAudio.Unusable) = made {
                self.record {
                    $0.audio = error.audio?.wav
                    $0.synthesis = error.audio?.synthesis
                }
            }
            Log.agents.error("natural voice unavailable; using the system voice")
            self.outcome(false, reason, self.attempt)
            self.speakWithFallback(text, because: reason)
        }
        making = task
    }

    private static func reason(for made: Result<SpokenAudio, any Error>) -> String {
        guard case .failure(let error) = made else { return "" }
        switch error {
        case let unusable as SpokenAudio.Unusable: return "the natural voice made \(unusable.problem.rawValue)"
        case is WorkBusy: return "the natural voice was still busy with earlier audio"
        case is DeadlineExceeded: return "the natural voice took too long"
        case is KokoroVoice.NotInstalled: return "the natural voice isn\u{2019}t installed"
        default: return "the natural voice failed"
        }
    }

    private func record(_ change: (inout SpokenAttempt) -> Void) {
        guard let attempt else { return }
        attempts?.update(attempt, change)
    }

    private func speakWithFallback(_ text: String, because reason: String) {
        macOSReason = reason
        record {
            $0.reader = .macOS
            $0.macOSReason = reason
            if $0.details.isEmpty { $0.details = details(false) }
        }
        active = .fallback
        fallback.speak(text, voice: nil)
        let limit = fallbackLimit(text)
        var task: Task<Void, Never>?
        task = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, self.watchdog == task, self.active == .fallback else { return }
            Log.agents.error("system voice did not finish; ending it")
            self.stop()
        }
        watchdog = task
    }

    func stop() {
        let wasSpeaking = active != nil
        silence()
        if wasSpeaking { onFinished?() }
    }

    private func silence() {
        if active != nil {
            record { if $0.playback == .playing { $0.playback = .interrupted } }
            attempts?.ended(attempt)
        }
        active = nil
        making?.cancel()
        making = nil
        watchdog?.cancel()
        watchdog = nil
        player.stop()
        fallback.stop()
    }

    private func ended(_ source: Source) {
        guard active == source else { return }
        active = nil
        watchdog?.cancel()
        watchdog = nil
        onFinished?()
    }
}

private final class UnfinishedSyntheses: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    var count: Int { lock.withLock { running } }
    func begin() { lock.withLock { running += 1 } }
    func end() { lock.withLock { running -= 1 } }
}
