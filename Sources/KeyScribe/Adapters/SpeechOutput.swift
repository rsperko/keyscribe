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
    func play(_ audio: Data) -> Bool
    func stop()
}

@MainActor
final class WAVPlayer: NSObject, AudioPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinished: (() -> Void)?

    var isPlaying: Bool { player?.isPlaying ?? false }
    var current: AVAudioPlayer? { player }

    func play(_ audio: Data) -> Bool {
        stop()
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
        Task { @MainActor in self.ended(finished) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let failed = ObjectIdentifier(player)
        Task { @MainActor in
            Log.agents.error("natural voice playback failed to decode")
            self.ended(failed)
        }
    }

    private func ended(_ finished: ObjectIdentifier) {
        guard let current = player, ObjectIdentifier(current) == finished else { return }
        current.stop()
        player = nil
        onFinished?()
    }
}

@MainActor
final class NaturalSpeech: SpeechSynthesizing {
    private enum Source { case making, player, fallback }

    private let ready: () -> Bool
    private let synthesize: @Sendable (String, String) async throws -> Data
    private let player: any AudioPlaying
    private let fallback: any SpeechSynthesizing
    private let outcome: (Bool) -> Void
    private let fallbackLimit: (String) -> Duration
    private var making: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var active: Source?
    var onStarted: (() -> Void)?
    var onFinished: (() -> Void)?

    init(
        ready: @escaping () -> Bool, synthesize: @escaping @Sendable (String, String) async throws -> Data,
        player: any AudioPlaying = WAVPlayer(), fallback: any SpeechSynthesizing = SystemSpeech(),
        outcome: @escaping (Bool) -> Void = { _ in },
        fallbackLimit: @escaping (String) -> Duration = NaturalSpeech.fallbackLimit
    ) {
        self.ready = ready
        self.synthesize = synthesize
        self.player = player
        self.fallback = fallback
        self.outcome = outcome
        self.fallbackLimit = fallbackLimit
        player.onFinished = { [weak self] in self?.ended(.player) }
        fallback.onStarted = { [weak self] in
            guard let self, self.active == .fallback else { return }
            self.onStarted?()
        }
        fallback.onFinished = { [weak self] in self?.ended(.fallback) }
    }

    var isSpeaking: Bool { active != nil }

    nonisolated static func fallbackLimit(_ text: String) -> Duration {
        .seconds(10) + .milliseconds(600 * text.split(whereSeparator: { $0.isWhitespace }).count)
    }

    func speak(_ text: String, voice: String?) {
        silence()
        guard ready() else { return speakWithFallback(text) }
        let voice = SpokenVoices.resolved(voice)
        let synthesize = synthesize
        active = .making
        var task: Task<Void, Never>?
        task = Task { [weak self] in
            let audio = try? await synthesize(text, voice)
            guard !Task.isCancelled, let self, self.making == task else { return }
            self.making = nil
            if let audio {
                self.active = .player
                if self.player.play(audio) {
                    self.outcome(true)
                    self.onStarted?()
                    return
                }
            }
            Log.agents.error("natural voice unavailable; using the system voice")
            self.outcome(false)
            self.speakWithFallback(text)
        }
        making = task
    }

    private func speakWithFallback(_ text: String) {
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
