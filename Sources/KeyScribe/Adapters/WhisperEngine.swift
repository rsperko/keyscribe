import Foundation
import KeyScribeKit
import WhisperKit

// Not an actor: WhisperKit's class isn't Sendable. `pipe` is serialized by the SerializedEngine actor
// decorator applied at EngineRegistry.makeAll (single-flight load; load/transcribe/evict never overlap),
// so `nonisolated(unsafe)` is safe — the decorator is the guarantee, not an "loads between dictations"
// assumption. Each profile owns its install subdir so reconcile/delete treats variants independently
// (Large v3 Turbo keeps the original "whisper" dir).
struct WhisperModelProfile {
    let id: String
    let displayName: String
    let variant: String
    let installDir: String
    let tokenizerRepo: String

    static let largeV3Turbo = WhisperModelProfile(
        id: "whisper", displayName: "Whisper Large v3 Turbo",
        variant: "openai_whisper-large-v3-v20240930_turbo_632MB", installDir: "whisper",
        tokenizerRepo: "openai/whisper-large-v3")
    static let smallEnglish = WhisperModelProfile(
        id: "whisper-small-en", displayName: "Whisper Small (English)",
        variant: "openai_whisper-small.en_217MB", installDir: "whisper-small-en",
        tokenizerRepo: "openai/whisper-small.en")
}

final class WhisperEngine: SpeechEngine, @unchecked Sendable {
    let id: String
    let displayName: String
    let supportsRecognitionBias = true
    let installDirNames: [String]

    private let variant: String
    private let installDir: String
    private let tokenizerRepo: String
    private let modelsDir: URL
    nonisolated(unsafe) private var pipe: WhisperKit?

    init(profile: WhisperModelProfile, modelsDir: URL) {
        self.id = profile.id
        self.displayName = profile.displayName
        self.variant = profile.variant
        self.installDir = profile.installDir
        self.tokenizerRepo = profile.tokenizerRepo
        self.installDirNames = [profile.installDir]
        self.modelsDir = modelsDir
    }

    func loadIfNeeded() async throws {
        try await load(progress: nil, allowRepair: false)
    }

    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        try await load(progress: progress, allowRepair: true)
    }

    private func load(progress: (@Sendable (ModelLoadProgress) -> Void)?, allowRepair: Bool) async throws {
        guard pipe == nil else { return }
        // Reserve a tail of the bar for the opaque CoreML load/compile step (no progress callback), so
        // the download doesn't show 100% while WhisperKit loads the model.
        let downloadShare = 0.9
        let local = localModelFolder(in: modelsDir)
        if installComplete(in: modelsDir) {
            do {
                pipe = try await loadPipe(folder: local, progress: progress, downloadShare: downloadShare)
                progress?(.init(phase: "Ready", fraction: 1))
                return
            } catch {
                guard allowRepair else {
                    Log.models.error("whisper: load from present install failed (\(error.localizedDescription, privacy: .public)); not repairing on the dictation path")
                    throw error
                }
                Log.models.notice("whisper: install present but load failed (\(error.localizedDescription, privacy: .public)); re-downloading")
                try? FileManager.default.removeItem(at: local)
            }
        } else if !allowRepair {
            Log.models.error("whisper: install incomplete on the dictation path; not downloading")
            throw EngineError.notInitialized
        }
        let folder = try await WhisperKit.download(
            variant: variant, downloadBase: installBase,
            progressCallback: { p in
                progress?(.init(phase: "Downloading speech model…", fraction: p.fractionCompleted * downloadShare))
            })
        pipe = try await loadPipe(folder: folder, progress: progress, downloadShare: downloadShare)
        progress?(.init(phase: "Ready", fraction: 1))
    }

    private func loadPipe(
        folder: URL, progress: (@Sendable (ModelLoadProgress) -> Void)?, downloadShare: Double
    ) async throws -> WhisperKit {
        progress?(.init(phase: "Compiling speech model…", fraction: downloadShare))
        // GPU, not ANE: WhisperKit's default .cpuAndNeuralEngine pays a ~140 s first-load ANE
        // device-compile that measured as failing to cache (paid EVERY load). .cpuAndGPU compiles Metal
        // shaders once (~24 s first, ~2 s cached, persisted across launches) at a slightly higher RTF —
        // load saving dominates for an intermittent dictation model.
        let compute = ModelComputeOptions(
            melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)
        // Pin the tokenizer under installBase — the Hub default writes it to ~/Documents/huggingface,
        // triggering a Documents TCC prompt.
        let config = WhisperKitConfig(
            modelFolder: folder.path, tokenizerFolder: installBase, computeOptions: compute,
            verbose: false, prewarm: false, load: true, download: false)
        return try await WhisperKit(config)
    }

    private var installBase: URL {
        modelsDir.appendingPathComponent(installDir, isDirectory: true)
    }

    // WhisperKit.download snapshots the whole whisperkit-coreml repo under downloadBase, hence the
    // nested argmaxinc/whisperkit-coreml/<variant> path.
    private func localModelFolder(in modelsDir: URL) -> URL {
        modelsDir
            .appendingPathComponent(installDir, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    // A partial cache (interrupted download) must NOT count as "installed" — offline load would fail
    // and reconcile could keep a broken install.
    private static let requiredBundles = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    private func modelFilesPresent(at folder: URL) -> Bool {
        let fm = FileManager.default
        return Self.requiredBundles.allSatisfy { name in
            fm.fileExists(atPath: folder.appendingPathComponent("\(name).mlmodelc").path)
                || fm.fileExists(atPath: folder.appendingPathComponent("\(name).mlpackage").path)
        }
    }

    private func tokenizerPresent(in modelsDir: URL) -> Bool {
        let path = modelsDir
            .appendingPathComponent(installDir, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(tokenizerRepo, isDirectory: true)
            .appendingPathComponent("tokenizer.json")
        return FileManager.default.fileExists(atPath: path.path)
    }

    private func installComplete(in modelsDir: URL) -> Bool {
        modelFilesPresent(at: localModelFolder(in: modelsDir)) && tokenizerPresent(in: modelsDir)
    }

    func verifyInstalled(in modelsDir: URL) -> Bool? {
        installComplete(in: modelsDir)
    }

    nonisolated var supportsSampleInput: Bool { true }

    // Routed through the samples entry (not WhisperKit's audioPath) so the short-audio padding below
    // covers the WAV path too — audioPath would feed a sub-1s file into the unpadded seek loop.
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        try await transcribe(
            samples: try AudioDecoder.pcmMono(wavURL, sampleRate: WhisperKit.sampleRate),
            sampleRate: WhisperKit.sampleRate, biasTerms: biasTerms)
    }

    func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()
        guard let pipe else { throw EngineError.notInitialized }
        let options = decodeOptions(biasTerms: biasTerms, pipe: pipe)
        Log.bias.info("whisper samples terms=\(biasTerms.joined(separator: "|"), privacy: .private) promptTokens=\(options.promptTokens?.count ?? 0, privacy: .public)")
        let audio = Self.paddedForDecode(samples, windowClipTime: options.windowClipTime)
        let results = try await pipe.transcribe(audioArray: audio, decodeOptions: options)
        return results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // WhisperKit's seek loop stops `windowClipTime` (default 1 s) short of the clip end to avoid
    // end-of-window hallucinations, so a clip SHORTER than that never enters the loop — false "No speech
    // detected" on any sub-second utterance. Pad just past the guard with trailing zeros (same zero-fill
    // WhisperKit uses to reach the 30 s window); a ≥1 s clip is unaffected.
    static func paddedForDecode(_ samples: [Float], windowClipTime: Float) -> [Float] {
        let minFrames = Int(windowClipTime * Float(WhisperKit.sampleRate)) + 1
        guard samples.count < minFrames else { return samples }
        return samples + [Float](repeating: 0, count: minFrames - samples.count)
    }

    // Whisper bias = conditioning prompt: dictionary terms tokenized and prepended as `promptTokens`,
    // nudging the decoder toward those spellings — a soft hint, not a guarantee. Requires our fork's
    // prefill-completion fix (Package.swift): stock WhisperKit 1.0.0 aborts to an empty transcript
    // whenever `promptTokens` are set.
    private func decodeOptions(biasTerms: [String], pipe: WhisperKit) -> DecodingOptions {
        Self.batchDecodingOptions(promptTokens: promptTokens(biasTerms: biasTerms, pipe: pipe))
    }

    private func promptTokens(biasTerms: [String], pipe: WhisperKit) -> [Int]? {
        guard !biasTerms.isEmpty, let tokenizer = pipe.tokenizer else { return nil }
        let promptText = " " + biasTerms.joined(separator: ", ")
        let tokens = tokenizer.encode(text: promptText).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }

    // WhisperKit's default firstTokenLogProbThreshold (-1.5) early-stops a window whose first token is
    // low-confidence, keeping zero word tokens — a short fast utterance can surface an intermittent false
    // "No speech detected". Batch push-to-talk knows the user spoke, so disable that latency gate; true
    // silence still returns "" via end-of-text.
    static func batchDecodingOptions(promptTokens: [Int]?) -> DecodingOptions {
        var options = DecodingOptions(promptTokens: promptTokens)
        options.firstTokenLogProbThreshold = nil
        return options
    }

    func evict() async {
        pipe = nil
    }
}
