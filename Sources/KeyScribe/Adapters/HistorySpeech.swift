import Foundation

@MainActor
final class HistorySpeech {
    enum Start: Equatable { case started, dictating, failed }

    private let audio: HeldAudioSpeech
    private let voice: any SpeechSynthesizing
    private let silencer: SpeechSilencer
    private var current: (speech: AnyObject, onEnd: () -> Void)?

    init(audio: HeldAudioSpeech = HeldAudioSpeech(), voice: any SpeechSynthesizing = SystemSpeech(), silencer: SpeechSilencer = .shared) {
        self.audio = audio
        self.voice = voice
        self.silencer = silencer
        for speech in [audio, voice] as [any SpeechSynthesizing] {
            silencer.register(speech)
            speech.onFinished = { [weak self, weak speech] in
                guard let self, let speech else { return }
                self.silencer.released(speech)
                self.ended(speech)
            }
        }
    }

    func play(_ data: Data, onEnd: @escaping () -> Void) -> Start {
        guard !silencer.isRecording else { return .dictating }
        audio.prepare(data)
        return start(audio, text: "", onEnd: onEnd)
    }

    func read(_ text: String, onEnd: @escaping () -> Void) -> Start {
        guard !silencer.isRecording else { return .dictating }
        return start(voice, text: text, onEnd: onEnd)
    }

    func stop() {
        audio.stop()
        voice.stop()
    }

    private func start(_ speech: any SpeechSynthesizing, text: String, onEnd: @escaping () -> Void) -> Start {
        current = (speech, onEnd)
        silencer.speak(text, voice: nil, with: speech)
        guard speech.isSpeaking else {
            if current?.speech === speech { current = nil }
            return .failed
        }
        return .started
    }

    private func ended(_ speech: AnyObject) {
        guard let current, current.speech === speech else { return }
        self.current = nil
        current.onEnd()
    }
}
