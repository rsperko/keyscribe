import AudioCommon
import Foundation
import Qwen3ASR
import KeyScribeKit
import os

// Per-model identity bundled so adding a Qwen3-ASR variant is adding a profile constant, not editing
// the engine. `modelId` is the HuggingFace MLX bundle; `subdir` roots its weights under modelsDir so
// each variant's cache is isolated (delete one without touching the other).
struct Qwen3ModelProfile {
    let id: String
    let displayName: String
    let modelId: String
    let subdir: String

    static let small = Qwen3ModelProfile(
        id: "qwen3-asr-0.6b", displayName: "Qwen3-ASR 0.6B",
        modelId: Qwen3ASRModel.defaultModelId, subdir: "qwen3-asr-0.6b")
    static let large = Qwen3ModelProfile(
        id: "qwen3-asr-1.7b", displayName: "Qwen3-ASR 1.7B",
        modelId: Qwen3ASRModel.largeModelId, subdir: "qwen3-asr-1.7b")
}

// One adapter, parameterized per Qwen3-ASR variant. MLX/Metal backend: weights download from
// HuggingFace into modelsDir, then run on the GPU via MLX. Recognition bias is native — dictionary
// terms are passed as the decoder `context`, an LLM-style prompt prefix that nudges recognition
// toward those spellings (proven: "KeyScribe" misheard as "Stan word" without context, correct with).
//
// Not an actor: Qwen3ASRModel isn't Sendable (and is documented not thread-safe). Access is
// serialized by the commit-on-release dictation state machine — load/evict happen between
// dictations, never during one — so `nonisolated(unsafe)` storage is the SDK-edge pattern, not a
// race. Same shape as WhisperEngine.
//
// Requires `mlx.metallib` next to the executable inside the .app: without it MLX hard-fails at the
// first GPU op ("Failed to load the default metallib"). make-app.sh builds and bundles it.
final class Qwen3ASREngine: SpeechEngine, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let supportsRecognitionBias = true
    var installDirNames: [String] { [subdir] }

    private let modelId: String
    private let subdir: String
    private let modelsDir: URL
    nonisolated(unsafe) private var model: Qwen3ASRModel?

    init(profile: Qwen3ModelProfile, modelsDir: URL) {
        self.id = profile.id
        self.displayName = profile.displayName
        self.modelId = profile.modelId
        self.subdir = profile.subdir
        self.modelsDir = modelsDir
    }

    func loadIfNeeded() async throws {
        try await load(progress: nil)
    }

    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        guard model == nil else { return }
        // Download fills 0–0.9 of the bar; the MLX weight load/first-op warm-up fills the tail.
        let downloadShare = 0.9
        let bridge: (@Sendable (Double, String) -> Void)?
        if let report = progress {
            bridge = { (fraction: Double, phase: String) in
                let clamped = min(max(fraction, 0), 1) * downloadShare
                report(ModelLoadProgress(phase: phase, fraction: clamped))
            }
        } else {
            bridge = nil
        }
        // Root each variant under its own modelsDir/<subdir> so the two coexist and reconcile can
        // own/delete them by id. getCacheDirectory ignores cacheDirName when basePath is set, so the
        // per-variant isolation has to come from basePath, not cacheDirName.
        let cacheDir = try HuggingFaceDownloader.getCacheDirectory(
            for: modelId, basePath: modelsDir.appendingPathComponent(subdir, isDirectory: true))
        model = try await Qwen3ASRModel.fromPretrained(
            modelId: modelId, cacheDir: cacheDir, progressHandler: bridge)
        progress?(.init(phase: "Ready", fraction: 1))
    }

    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()
        guard let model else { throw EngineError.notInitialized }
        let audio = try AudioDecoder.pcmMono(wavURL, sampleRate: 24000)
        let context = biasTerms.isEmpty ? nil : biasTerms.joined(separator: ", ")
        Log.bias.info("qwen3asr terms=\(biasTerms.joined(separator: "|"), privacy: .private) context=\(context != nil, privacy: .public)")
        let text = model.transcribe(audio: audio, sampleRate: 24000, context: context)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func evict() async {
        model = nil
    }
}
