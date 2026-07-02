import Foundation
import KeyScribeKit
import WhisperKit

// WhisperKit (now the Argmax OSS SDK monorepo, argmax-oss-swift, pinned 1.0.0 — the WhisperKit
// product only; Vapor/openapi stay out of resolution, gated behind the SDK's BUILD_ALL flag).
// CoreML/ANE like FluidAudio. Models live under modelsDir/whisper (downloaded once via Hugging
// Face, then loaded with download disabled); the turbo variant balances accuracy and the ~632MB
// footprint.
//
// Not an actor: WhisperKit's class isn't Sendable, so an actor can't await its nonisolated methods
// without "sending" the instance off-actor. Every access to the `pipe` handle is serialized by the
// SerializedEngine actor decorator that wraps this engine at EngineRegistry.makeAll (load is single-
// flight; load/transcribe/evict never overlap), so `nonisolated(unsafe)` storage is safe here — that
// decorator, not an informal "loads happen between dictations" assumption, is the guarantee.
// Per-model identity bundled so adding a Whisper model is adding a profile constant, not editing
// the engine. Each profile owns its own install subdir under modelsDir so reconcile/delete treats
// the variants independently (the Large v3 Turbo keeps the original "whisper" dir for back-compat).
struct WhisperModelProfile {
    let id: String
    let displayName: String
    let variant: String
    let installDir: String

    static let largeV3Turbo = WhisperModelProfile(
        id: "whisper", displayName: "Whisper Large v3 Turbo",
        variant: "openai_whisper-large-v3-v20240930_turbo_632MB", installDir: "whisper")
    static let smallEnglish = WhisperModelProfile(
        id: "whisper-small-en", displayName: "Whisper Small (English)",
        variant: "openai_whisper-small.en_217MB", installDir: "whisper-small-en")
}

final class WhisperEngine: SpeechEngine, @unchecked Sendable {
    let id: String
    let displayName: String
    let supportsRecognitionBias = true
    let installDirNames: [String]

    private let variant: String
    private let installDir: String
    private let modelsDir: URL
    nonisolated(unsafe) private var pipe: WhisperKit?

    init(profile: WhisperModelProfile, modelsDir: URL) {
        self.id = profile.id
        self.displayName = profile.displayName
        self.variant = profile.variant
        self.installDir = profile.installDir
        self.installDirNames = [profile.installDir]
        self.modelsDir = modelsDir
    }

    func loadIfNeeded() async throws {
        try await load(progress: nil)
    }

    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        guard pipe == nil else { return }
        // Reserve a tail of the bar for the opaque CoreML load/compile step, which has no progress
        // callback — so the download doesn't prematurely show 100% while WhisperKit loads ~632 MB.
        let downloadShare = 0.9
        let local = localModelFolder(in: modelsDir)
        if modelFilesPresent(at: local) {
            do {
                pipe = try await loadPipe(folder: local, progress: progress, downloadShare: downloadShare)
                progress?(.init(phase: "Ready", fraction: 1))
                return
            } catch {
                Log.models.notice("whisper: offline load from present folder failed (\(error.localizedDescription, privacy: .public)); re-downloading")
                try? FileManager.default.removeItem(at: local)
            }
        }
        let base = modelsDir.appendingPathComponent(installDir, isDirectory: true)
        let folder = try await WhisperKit.download(
            variant: variant, downloadBase: base,
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
        // Run on the GPU, not the Neural Engine. WhisperKit defaults the audio encoder and text decoder to
        // .cpuAndNeuralEngine, whose first-load ANE device-compile of this 632 MB model takes ~140 s — and
        // here it failed to cache, paying that cost on EVERY load. .cpuAndGPU compiles Metal shaders once
        // (~24 s first ever, ~2 s from cache thereafter, persisted across launches) at the cost of a slightly
        // higher RTF (~0.12, still 8× faster than real time). For an intermittently-used dictation model the
        // load saving dominates; bias (promptTokens) is unaffected.
        let compute = ModelComputeOptions(
            melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)
        let config = WhisperKitConfig(
            modelFolder: folder.path, computeOptions: compute,
            verbose: false, prewarm: false, load: true, download: false)
        return try await WhisperKit(config)
    }

    // WhisperKit.download snapshots the whisperkit-coreml repo under downloadBase, so the variant's
    // CoreML bundles land at <installDir>/models/argmaxinc/whisperkit-coreml/<variant>.
    private func localModelFolder(in modelsDir: URL) -> URL {
        modelsDir
            .appendingPathComponent(installDir, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    // WhisperKit loads three CoreML bundles by name (MelSpectrogram, AudioEncoder, TextDecoder). Require
    // ALL of them: a partial cache (an interrupted download that landed only one) must NOT be adopted as
    // "installed" — offline load would then fail and reconcile could keep a broken install.
    private static let requiredBundles = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    private func modelFilesPresent(at folder: URL) -> Bool {
        let fm = FileManager.default
        return Self.requiredBundles.allSatisfy { name in
            fm.fileExists(atPath: folder.appendingPathComponent("\(name).mlmodelc").path)
                || fm.fileExists(atPath: folder.appendingPathComponent("\(name).mlpackage").path)
        }
    }

    // The CoreML bundles are a checkable install footprint, so reconcile does not need the marker to
    // know the model is present — a completed-but-unmarked download is adopted rather than deleted.
    func verifyInstalled(in modelsDir: URL) -> Bool? {
        modelFilesPresent(at: localModelFolder(in: modelsDir))
    }

    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()
        guard let pipe else { throw EngineError.notInitialized }
        let options = decodeOptions(biasTerms: biasTerms, pipe: pipe)
        Log.bias.info("whisper terms=\(biasTerms.joined(separator: "|"), privacy: .private) promptTokens=\(options?.promptTokens?.count ?? 0, privacy: .public)")
        let results = try await pipe.transcribe(audioPath: wavURL.path, decodeOptions: options)
        return results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Recognition bias for Whisper is its conditioning prompt: dictionary terms are tokenized and
    // prepended as `promptTokens`, nudging the decoder toward those spellings (design.md §4.2). This
    // is a soft hint the model may ignore, not a guarantee — only nonce tokens survive a rewrite.
    // Word tokens only (drop special tokens); nil options when there's nothing to bias.
    //
    // Requires the prefill-completion fix in our WhisperKit fork (see Package.swift): stock 1.0.0
    // aborts the decode to an empty transcript whenever `promptTokens` are set (#372).
    private func decodeOptions(biasTerms: [String], pipe: WhisperKit) -> DecodingOptions? {
        guard !biasTerms.isEmpty, let tokenizer = pipe.tokenizer else { return nil }
        let promptText = " " + biasTerms.joined(separator: ", ")
        let tokens = tokenizer.encode(text: promptText).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        guard !tokens.isEmpty else { return nil }
        return DecodingOptions(promptTokens: tokens)
    }

    func evict() async {
        pipe = nil
    }
}
