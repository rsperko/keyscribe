import AVFoundation
import FluidAudio
import KeyScribeKit

// NVIDIA Nemotron Speech 3.5 streaming (English, en-0.6b CoreML), driven in one-shot batch mode for
// KeyScribe's commit-on-release dictation — feed the whole clip, then finish. Nemotron has no on-device
// vocabulary-bias path (no customVocabulary input), so it is bias-exempt like Moonshine, ignores
// biasTerms, and earns dictionary-term recovery only through the post-STT fuzzy stage.
actor NemotronEngine: SpeechEngine {
    nonisolated let id = "nemotron-en"
    nonisolated let displayName = "Nemotron Speech 3.5 (English)"
    nonisolated let supportsRecognitionBias = false
    // The 2240 ms tier downloads to modelsDir/<repo.folderName>; the top component is the deletable tree.
    nonisolated let installDirNames = ["nemotron-speech-streaming-en-0.6b-coreml"]

    private let modelsDir: URL
    private var manager: StreamingNemotronAsrManager?

    init(modelsDir: URL) {
        self.modelsDir = modelsDir
    }

    func loadIfNeeded() async throws {
        try await load(progress: nil)
    }

    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        guard manager == nil else { return }
        let m = StreamingNemotronAsrManager()
        // Download fills 0–0.9; the CoreML compile/load tail fills the rest (no callback for that step).
        let downloadShare = 0.9
        var handler: DownloadUtils.ProgressHandler?
        if let progress {
            handler = { snapshot in
                progress(.init(phase: "Downloading speech model…", fraction: snapshot.fractionCompleted * downloadShare))
            }
        }
        progress?(.init(phase: "Downloading speech model…", fraction: 0))
        try await m.loadModels(to: modelsDir, progressHandler: handler)
        progress?(.init(phase: "Ready", fraction: 1))
        manager = m
    }

    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()
        guard let manager else { throw EngineError.notInitialized }
        await manager.reset()
        let file = try AVAudioFile(forReading: wavURL)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw EngineError.notInitialized }
        try file.read(into: buffer)
        _ = try await manager.process(audioBuffer: buffer)
        return try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func evict() async {
        await manager?.reset()
        manager = nil
    }
}
