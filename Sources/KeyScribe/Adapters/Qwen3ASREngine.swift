import AudioCommon
import Foundation
import Qwen3ASR
import KeyScribeKit

// `modelId` is the HuggingFace MLX bundle; `subdir` roots its weights under modelsDir so each variant's
// cache is isolated (delete one without touching the other).
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

// Recognition bias is native — dictionary terms are passed as the decoder `context`, an LLM-style
// prompt prefix that nudges recognition toward those spellings (proven: "KeyScribe" misheard as
// "Stan word" without context, correct with).
//
// Not an actor: Qwen3ASRModel isn't Sendable (documented not thread-safe). Access to `model` is
// serialized by the SerializedEngine actor decorator wrapping this engine at EngineRegistry.makeAll
// (single-flight load; load/transcribe/evict never overlap), so `nonisolated(unsafe)` storage is safe.
//
// Requires `mlx.metallib` next to the executable inside the .app: without it MLX hard-fails at the
// first GPU op ("Failed to load the default metallib"). make-app.sh builds and bundles it.
final class Qwen3ASREngine: SpeechEngine, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let supportsRecognitionBias = true
    nonisolated let captureSampleRate = 24000
    var installDirNames: [String] { [subdir] }

    private let modelId: String
    private let subdir: String
    private let modelsDir: URL
    nonisolated(unsafe) private var model: Qwen3ASRModel?
    // MLX inference is a synchronous, whole-clip call; running it on a Swift-concurrency pool thread
    // would park a cooperative worker for the duration. SerializedEngine still guarantees one transcribe
    // at a time on this instance.
    private let inferenceQueue = DispatchQueue(label: "com.keyscribe.audio.qwen3asr-inference", qos: .userInitiated)

    init(profile: Qwen3ModelProfile, modelsDir: URL) {
        self.id = profile.id
        self.displayName = profile.displayName
        self.modelId = profile.modelId
        self.subdir = profile.subdir
        self.modelsDir = modelsDir
    }

    func loadIfNeeded() async throws {
        try await load(progress: nil, allowRepair: false)
    }

    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        try await load(progress: progress, allowRepair: true)
    }

    private func load(progress: (@Sendable (ModelLoadProgress) -> Void)?, allowRepair: Bool) async throws {
        guard model == nil else { return }
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
        // getCacheDirectory ignores cacheDirName when basePath is set, so per-variant isolation has to
        // come from basePath.
        let cacheDir = try HuggingFaceDownloader.getCacheDirectory(
            for: modelId, basePath: modelsDir.appendingPathComponent(subdir, isDirectory: true))
        let offline = fullInstallPresent(in: cacheDir)
        do {
            model = try await Qwen3ASRModel.fromPretrained(
                modelId: modelId, cacheDir: cacheDir, offlineMode: offline, progressHandler: bridge)
        } catch {
            guard offline else { throw error }
            guard allowRepair else {
                Log.models.error("qwen3asr: load from present install failed (\(error.localizedDescription, privacy: .public)); not repairing on the dictation path")
                throw error
            }
            Log.models.notice("qwen3asr: offline load failed (\(error.localizedDescription, privacy: .public)); re-downloading")
            try? FileManager.default.removeItem(at: cacheDir)
            model = try await Qwen3ASRModel.fromPretrained(
                modelId: modelId, cacheDir: cacheDir, offlineMode: false, progressHandler: bridge)
        }
        progress?(.init(phase: "Ready", fraction: 1))
    }

    // weightsExist passes on ANY single .safetensors, so an interrupted download (weight shard but no
    // vocab.json) would load with the tokenizer silently skipped, pasting space-joined raw token IDs.
    // Require the whole set so a partial install is treated as absent, never loaded.
    private static let requiredSidecars = ["config.json", "vocab.json", "merges.txt", "tokenizer_config.json"]

    func fullInstallPresent(in cacheDir: URL) -> Bool {
        guard HuggingFaceDownloader.weightsExist(in: cacheDir) else { return false }
        let fm = FileManager.default
        return Self.requiredSidecars.allSatisfy {
            fm.fileExists(atPath: cacheDir.appendingPathComponent($0).path)
        }
    }

    private func existingCacheDirectory(in modelsDir: URL) -> URL {
        let base = modelsDir.appendingPathComponent(subdir, isDirectory: true)
        let old = base.appendingPathComponent(
            HuggingFaceDownloader.sanitizedCacheKey(for: modelId), isDirectory: true)
        if HuggingFaceDownloader.weightsExist(in: old) { return old }
        return base.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelId, isDirectory: true)
    }

    // A completed-but-unmarked download (crash before the marker wrote) is adopted rather than deleted;
    // a partial install (missing tokenizer/config) reports false so it is not adopted.
    nonisolated func verifyInstalled(in modelsDir: URL) -> Bool? {
        fullInstallPresent(in: existingCacheDirectory(in: modelsDir))
    }

    nonisolated var supportsSampleInput: Bool { true }

    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        try await transcribe(samples: try AudioDecoder.pcmMono(wavURL, sampleRate: 24000), sampleRate: 24000, biasTerms: biasTerms)
    }

    func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()
        let context = biasTerms.isEmpty ? nil : biasTerms.joined(separator: ", ")
        Log.bias.info("qwen3asr terms=\(biasTerms.joined(separator: "|"), privacy: .private) context=\(context != nil, privacy: .public)")
        let text = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            inferenceQueue.async { [self] in
                guard let model else { cont.resume(throwing: EngineError.notInitialized); return }
                cont.resume(returning: model.transcribe(audio: samples, sampleRate: sampleRate, context: context))
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Do NOT reduce this to `model = nil`: MLX recycles a dropped model's buffers into a process-wide
    // cache pool rather than returning them to the OS, so the GPU working set stays resident (measured:
    // multi-GB after a bare nil, 0 after clearCache). unload() frees parameters and clears MLX's cache.
    // The clear is process-wide but safe against a concurrent load/transcribe of the other Qwen variant:
    // MLX's MetalAllocator guards malloc/free/clear_cache with one mutex, and clear_cache empties only
    // the reusable-buffer pool, never a buffer a live MLXArray holds.
    func evict() async {
        model?.unload()
        model = nil
    }
}
