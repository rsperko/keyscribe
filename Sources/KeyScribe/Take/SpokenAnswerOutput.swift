import Foundation
import KeyScribeKit

@MainActor
final class SpokenAnswerOutput {
    private struct Answer {
        let name: String
        let text: String
        let spoken: String
        let since: DispatchTime
        var heard = false
    }

    private let speech: any SpeechSynthesizing
    private let silencer: SpeechSilencer
    private let voice: () -> String?
    private let textOnly: () -> Bool
    private let warm: () -> Void
    private let release: () -> Void
    private let duck: (Bool) -> Void
    private var pending: Answer?
    private var playing: Answer?
    private var audible = false
    private var holdsVoice = false
    private(set) var showsText = false
    var onShow: ((_ name: String, _ text: String, _ spoken: Bool) -> Void)?
    var onSpeaking: (() -> Void)?
    var onEnded: (() -> Void)?
    var onClosed: (() -> Void)?
    var onFirstAudio: ((Double) -> Void)?

    init(
        speech: any SpeechSynthesizing, silencer: SpeechSilencer = .shared, voice: @escaping () -> String?,
        textOnly: @escaping () -> Bool = { false }, warm: @escaping () -> Void = {}, release: @escaping () -> Void = {}, duck: @escaping (Bool) -> Void = { _ in }
    ) {
        self.speech = speech
        self.silencer = silencer
        self.voice = voice
        self.textOnly = textOnly
        self.warm = warm
        self.release = release
        self.duck = duck
        speech.onStarted = { [weak self] in self?.started() }
        speech.onFinished = { [weak self] in self?.ended() }
        silencer.register(speech)
        silencer.onAvailableFirst = { [weak self] in self?.playPending() }
    }

    var isActive: Bool { pending != nil || playing != nil }

    func prepare() {
        guard !textOnly() else { return }
        holdsVoice = true
        warm()
    }

    func answer(_ text: String, name: String, since: DispatchTime) {
        halt(releasing: false)
        guard !textOnly() else {
            letVoiceGo()
            showsText = true
            onShow?(name, text, false)
            return
        }
        holdsVoice = true
        pending = Answer(name: name, text: text, spoken: SpokenResult.spokenForm(text), since: since)
        onShow?(name, text, true)
        playPending()
    }

    func stop() { halt(releasing: true) }

    func settingsChanged() {
        guard textOnly(), let answer = playing ?? pending else { return }
        showAsText(answer)
    }

    private func showAsText(_ answer: Answer) {
        halt(releasing: true, keepingText: true)
        onShow?(answer.name, answer.text, false)
    }

    func close() {
        stop()
        onClosed?()
    }

    func takeEnded() {
        guard !isActive else { return }
        letVoiceGo()
    }

    private func halt(releasing: Bool, keepingText: Bool = false) {
        let wasActive = isActive
        let wasPlaying = playing != nil
        showsText = keepingText
        pending = nil
        playing = nil
        if wasPlaying { speech.stop() }
        setAudible(false)
        if wasActive { onEnded?() }
        guard releasing else { return }
        if wasPlaying { silencer.released(speech) }
        letVoiceGo()
    }

    private func playPending() {
        guard let answer = pending, playing == nil, silencer.mayInterrupt else { return }
        if textOnly() { return showAsText(answer) }
        pending = nil
        playing = answer
        silencer.speak(answer.spoken, voice: voice(), with: speech, resumingInterrupted: true)
        if !speech.isSpeaking {
            playing = nil
            onEnded?()
            letVoiceGo()
        }
    }

    private func started() {
        guard let answer = playing, !answer.heard else { return }
        playing?.heard = true
        setAudible(true)
        onSpeaking?()
        onFirstAudio?(Double(DispatchTime.now().uptimeNanoseconds - answer.since.uptimeNanoseconds) / 1e6)
    }

    private func ended() {
        guard playing != nil else { return }
        playing = nil
        setAudible(false)
        onEnded?()
        silencer.released(speech)
        letVoiceGo()
    }

    private func letVoiceGo() {
        guard holdsVoice, !isActive else { return }
        holdsVoice = false
        release()
    }

    private func setAudible(_ wanted: Bool) {
        guard wanted != audible else { return }
        audible = wanted
        duck(wanted)
    }
}
