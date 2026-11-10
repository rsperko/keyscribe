import Foundation

@MainActor
final class HeldAudioSpeech: SpeechSynthesizing {
    private let player: any AudioPlaying
    private var audio: Data?
    var onStarted: (() -> Void)?
    var onFinished: (() -> Void)?

    init(player: any AudioPlaying = WAVPlayer()) {
        self.player = player
        player.onFinished = { [weak self] in self?.ended() }
    }

    var isSpeaking: Bool { player.isPlaying }

    func prepare(_ audio: Data) { self.audio = audio }

    func speak(_ text: String, voice: String?) {
        guard let audio else { return }
        self.audio = nil
        guard player.play(audio) else { return ended() }
        onStarted?()
    }

    func stop() {
        guard player.isPlaying else { return }
        player.stop()
        ended()
    }

    private func ended() { onFinished?() }
}
