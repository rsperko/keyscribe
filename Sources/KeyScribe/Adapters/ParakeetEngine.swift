import Foundation
import FluidAudio
import KeyScribeKit

struct ParakeetModelProfile {
    let id: String
    let displayName: String
    let version: AsrModelVersion

    static let tdtV3 = ParakeetModelProfile(
        id: "parakeet", displayName: "Parakeet TDT v3", version: .v3)
    static let tdtCtc110m = ParakeetModelProfile(
        id: "parakeet-tdt-ctc-110m", displayName: "Parakeet TDT-CTC 110M", version: .tdtCtc110m)
}

actor ParakeetEngine: SpeechEngine {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let supportsRecognitionBias = false

    // Dir names come from FluidAudio (never hardcoded): the TDT bundle, plus — for the 110M hybrid — the
    // CTC-head companion FluidAudio's load unconditionally fetches (~103 MB), unused (no recognition bias)
    // but owned here so it's counted in the footprint and removed when the model is deleted.
    nonisolated var installDirNames: [String] {
        var names = [AsrModels.defaultCacheDirectory(for: version).lastPathComponent]
        if version == .tdtCtc110m {
            names.append(CtcModels.defaultCacheDirectory(for: .ctc110m).lastPathComponent)
        }
        return names
    }

    // Unlike the other engines (no SDK integrity check, default `nil`), Parakeet can verify its TDT
    // bundle on disk.
    nonisolated func verifyInstalled(in modelsDir: URL) -> Bool? {
        let tdt = modelsDir.appendingPathComponent(
            AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
        return AsrModels.modelsExist(at: tdt, version: version)
    }

    private let modelsDir: URL
    private let version: AsrModelVersion

    private var manager: AsrManager?

    init(profile: ParakeetModelProfile, modelsDir: URL) {
        self.id = profile.id
        self.displayName = profile.displayName
        self.version = profile.version
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
        var handler: DownloadUtils.ProgressHandler?
        if let progress {
            handler = { snapshot in
                progress(.init(phase: "Downloading speech model…", fraction: snapshot.fractionCompleted * 0.9))
            }
        }
        // FluidAudio's `to:` is the full model-bundle path (it downloads into the parent), so
        // target the bundle *inside* models/.
        let target = modelsDir.appendingPathComponent(
            AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
        let models = try await AsrModels.downloadAndLoad(
            to: target, version: version, progressHandler: handler)
        progress?(.init(phase: "Compiling speech model…", fraction: 0.95))
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    nonisolated let supportsSampleInput = true

    // biasTerms ignored — Parakeet has no recognition-bias path.
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()
        guard let manager else { throw EngineError.notInitialized }
        var decoderState = try TdtDecoderState(decoderLayers: version.decoderLayers)
        return try await manager.transcribe(wavURL, decoderState: &decoderState).text
    }

    // FluidAudio's sample APIs assume 16 kHz mono (the capture rate for Parakeet), so `sampleRate` is
    // informational. biasTerms ignored — Parakeet has no recognition-bias path.
    func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String {
        try await loadIfNeeded()
        guard let manager else { throw EngineError.notInitialized }
        var decoderState = try TdtDecoderState(decoderLayers: version.decoderLayers)
        return try await manager.transcribe(samples, decoderState: &decoderState).text
    }

    func evict() async {
        await manager?.cleanup()
        manager = nil
    }
}
