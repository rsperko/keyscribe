import Foundation
import FluidAudio
import KeyScribeKit

// Parakeet Unified EN 0.6B, offline batch path: a 15 s full-attention window with a 2 s overlap merge,
// so arbitrary-length dictations are handled inside the SDK.
//
// Two things set it apart from ParakeetEngine's TDT models, and both are why it is a separate adapter
// rather than a third ParakeetModelProfile: it is reached through UnifiedAsrManager (AsrModelVersion has
// no Unified case), and it emits punctuation and capitalization.
//
// Streaming is deliberately not wired. StreamingUnifiedAsrManager exists, but each latency tier is a
// distinct encoder bundle and a streaming session is its own no-speech path that needs its own silence
// sweep (AGENTS.md "A streaming session is a DISTINCT no-speech path").
actor ParakeetUnifiedEngine: SpeechEngine {
    nonisolated let id = "parakeet-unified-en"
    nonisolated let displayName = "Parakeet Unified 0.6B (English)"
    nonisolated let supportsRecognitionBias = false
    nonisolated let supportsSampleInput = true

    // The offline variant is selected by encoderPrecision, not by a variant string: the SDK maps
    // .int8 -> "offline" and .fp16 -> "offline-fp16" internally. int8 is the shipped choice — same
    // test-clean WER as fp16 at half the download.
    private static let precision: UnifiedEncoderPrecision = .int8
    private static var requiredFiles: Set<String> {
        ModelNames.ParakeetUnified.requiredModels(variant: "offline")
    }

    // From the SDK, never hardcoded. Repo.folderName returns a NESTED path for some repos
    // (e.g. "kokoro-82m-coreml/ANE"); reconcile matches last path components, so a nested name would
    // match nothing on disk and ModelInstallStore would reap the bundle as an orphan. Pinned by test.
    nonisolated var installDirNames: [String] { [Repo.parakeetUnified.folderName] }

    // Like ParakeetEngine, this one can check its own bundle: requiredModels(variant:) is the SDK's own
    // file list, so a half-finished download reads as not-installed instead of masquerading as complete.
    nonisolated func verifyInstalled(in modelsDir: URL) -> Bool? {
        Self.installIsComplete(at: Self.bundleDir(in: modelsDir))
    }

    private static func bundleDir(in modelsDir: URL) -> URL {
        modelsDir.appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
    }

    private static func installIsComplete(at bundle: URL) -> Bool {
        let fm = FileManager.default
        return requiredFiles.allSatisfy {
            fm.fileExists(atPath: bundle.appendingPathComponent($0).path)
        }
    }

    private let modelsDir: URL
    private var manager: UnifiedAsrManager?

    init(modelsDir: URL) {
        self.modelsDir = modelsDir
    }

    func loadIfNeeded() async throws {
        try await ensureManager(progress: nil)
    }

    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        try await ensureManager(progress: progress)
        progress?(.init(phase: "Ready", fraction: 1))
    }

    private func ensureManager(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        guard manager == nil else { return }
        var handler: ProgressHandler?
        if let progress {
            // Download and compile are one call here (unlike AsrModels.downloadAndLoad, which returns
            // between them), so the phase flips off the handler's own terminal snapshot.
            handler = { snapshot in
                if snapshot.fractionCompleted >= 1 {
                    progress(.init(phase: "Compiling speech model…", fraction: 0.95))
                } else {
                    progress(.init(
                        phase: "Downloading speech model…",
                        fraction: snapshot.fractionCompleted * 0.9))
                }
            }
        }
        let manager = UnifiedAsrManager(encoderPrecision: Self.precision)
        let bundle = Self.bundleDir(in: modelsDir)
        do {
            // This `to:` is the BASE models dir — the SDK appends Repo.parakeetUnified.folderName
            // itself. ParakeetEngine passes the FULL bundle path because AsrModels.download does the
            // opposite. Passing a bundle path here buries the models a level too deep, where
            // ModelInstallStore.reconcile sees an unclaimed directory and reaps it.
            try await manager.loadModels(to: modelsDir, progressHandler: handler)
        } catch {
            // The SDK's "already downloaded?" probe checks ONLY the encoder file, so an install that
            // died after the 595 MB encoder but before vocab.json would skip the download forever and
            // keep throwing. Clear a bundle that is genuinely incomplete so the next attempt refetches;
            // a complete bundle is left alone, since then the failure is not a partial download.
            if !Self.installIsComplete(at: bundle) {
                try? FileManager.default.removeItem(at: bundle)
            }
            throw error
        }
        self.manager = manager
    }

    // biasTerms ignored — Parakeet has no recognition-bias path.
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        let samples = try AudioDecoder.pcmMono(wavURL, sampleRate: captureSampleRate)
        return try await transcribe(
            samples: samples, sampleRate: captureSampleRate, biasTerms: biasTerms)
    }

    // FluidAudio's sample APIs assume 16 kHz mono (the capture rate for Parakeet), so `sampleRate` is
    // informational. Each window decodes from fresh RNNT state inside the SDK, so unlike the TDT path
    // there is no decoder state to thread through. biasTerms ignored — no recognition-bias path.
    func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()
        guard let manager else { throw EngineError.notInitialized }
        return try await manager.transcribe(samples)
    }

    func evict() async {
        await manager?.cleanup()
        manager = nil
    }
}
