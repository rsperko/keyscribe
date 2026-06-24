import Foundation
import MoonshineVoice
import KeyScribeKit

// Moonshine (Useful Sensors) — ONNX Runtime backend shipped as a prebuilt xcframework. Ultra-low
// latency English ASR. The .ort model files download directly from download.moonshine.ai into
// modelsDir/<subdir>; Transcriber loads that directory.
//
// Recognition bias: NOT supported on-device. Moonshine's on-device path has no hotword/context
// parameter (customization is a commercial retraining service), so this engine reports
// supportsRecognitionBias=false and ignores biasTerms. DictationController skips assembling terms
// for it, and the Settings models list badges it as no-local-bias.
//
// Not an actor: MoonshineVoice.Transcriber is a non-Sendable class; access is serialized by the
// commit-on-release dictation state machine (load/evict between dictations), so nonisolated(unsafe)
// storage is the SDK-edge pattern, like WhisperEngine/Qwen3ASREngine.
final class MoonshineEngine: SpeechEngine, @unchecked Sendable {
    let id = "moonshine-base-en"
    let displayName = "Moonshine Base (English)"
    let supportsRecognitionBias = false
    var installDirNames: [String] { [Self.subdir] }

    private static let baseURL = "https://download.moonshine.ai/model/base-en/quantized/base-en"
    // Approx download weights (decoder dominates) so the progress bar tracks reality across files.
    private static let files: [(name: String, weight: Double)] = [
        ("encoder_model.ort", 0.22), ("decoder_model_merged.ort", 0.77), ("tokenizer.bin", 0.01),
    ]
    private static let subdir = "moonshine-base-en"

    private let modelsDir: URL
    nonisolated(unsafe) private var transcriber: Transcriber?

    init(modelsDir: URL) {
        self.modelsDir = modelsDir
    }

    private var modelDir: URL { modelsDir.appendingPathComponent(Self.subdir, isDirectory: true) }

    func loadIfNeeded() async throws {
        try await load(progress: nil)
    }

    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        guard transcriber == nil else { return }
        let dir = modelDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cumulative = 0.0
        for file in Self.files {
            let dest = dir.appendingPathComponent(file.name)
            if !FileManager.default.fileExists(atPath: dest.path) {
                progress?(.init(phase: "Downloading speech model…", fraction: cumulative))
                guard let url = URL(string: "\(Self.baseURL)/\(file.name)") else {
                    throw EngineError.badModelURL(file.name)
                }
                let (tmp, response) = try await URLSession.shared.download(from: url)
                // download(from:) does not throw on an HTTP error — a 404/5xx/auth body lands in `tmp`.
                // Promoting that as a .ort/tokenizer file fails opaquely later in Transcriber and, since
                // the bogus file now exists, blocks any retry. Require a 2xx + non-empty payload first.
                let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? Int
                guard ok, (size ?? 0) > 0 else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw EngineError.downloadFailed(file.name)
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
            }
            cumulative += file.weight
            progress?(.init(phase: "Downloading speech model…", fraction: cumulative))
        }
        progress?(.init(phase: "Loading speech model…", fraction: 0.97))
        do {
            transcriber = try Transcriber(modelPath: dir.path, modelArch: .base)
        } catch {
            // Loading failed against what's on disk (a corrupt/partial artifact from an earlier run).
            // Remove the model dir so the next attempt re-downloads instead of failing on it forever.
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        progress?(.init(phase: "Ready", fraction: 1))
    }

    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()
        guard let transcriber else { throw EngineError.notInitialized }
        Log.bias.info("moonshine bias unsupported — \(biasTerms.count, privacy: .public) term(s) ignored")
        let audio = try AudioDecoder.pcmMono(wavURL, sampleRate: 16000)
        let transcript = try transcriber.transcribeWithoutStreaming(audioData: audio, sampleRate: 16000)
        return transcript.lines.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func evict() async {
        transcriber?.close()
        transcriber = nil
    }
}
