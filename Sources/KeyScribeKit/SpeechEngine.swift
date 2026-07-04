import Foundation

public protocol SpeechEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportsRecognitionBias: Bool { get }
    // Sample rate (Hz) the capture path should record at for this engine, so the WAV needs no
    // resample before transcription. 16 kHz suits every engine except Qwen3-ASR (24 kHz).
    var captureSampleRate: Int { get }
    // Contract: once a model's install footprint is complete (verifyInstalled true, or the install marker
    // records it), load/loadIfNeeded must not re-fetch those model files. Engine SDKs may own additional
    // side caches outside installDirNames; adapters should keep those offline where the SDK exposes that
    // control. STT is always on-device, and normal cold loads should not make network metadata checks.
    func loadIfNeeded() async throws
    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String

    // True when the engine can transcribe already-decoded PCM directly, letting the capture path hand it
    // the samples the writer just produced instead of re-reading and re-decoding the WAV. Default false;
    // FluidAudio/WhisperKit/Qwen/Moonshine override it. Apple keeps the file (its analyzer takes a URL).
    var supportsSampleInput: Bool { get }
    // Transcribe mono Float32 PCM at `sampleRate` (the engine's captureSampleRate). Only called when
    // supportsSampleInput is true. `wavURL` is still written for archive/probe/fallback.
    func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String

    func evict() async

    // Preheat any per-dictation session state at press so it overlaps speech; fire-and-forget, default
    // no-op. Only Apple's one-shot SpeechAnalyzer needs it today.
    func prepareForDictation() async

    // False for Apple: its analyzer is one-shot, so a warmup transcribe would consume the pair prepared for
    // the real dictation (prepareForDictation is its warmup instead).
    var benefitsFromWarmupClip: Bool { get }

    // Install footprint owned by this engine, used by reconcile/delete. The subdirectory names
    // (under modelsDir) the engine downloads into; empty for system-managed engines.
    var installDirNames: [String] { get }
    func verifyInstalled(in modelsDir: URL) -> Bool?
}

public extension SpeechEngine {
    // Default: a download with no native progress just loads. Downloadable engines override to report
    // byte/phase progress.
    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        try await loadIfNeeded()
    }

    // Defaults suit system-managed engines and any engine that defers to the install marker.
    var installDirNames: [String] { [] }
    func verifyInstalled(in modelsDir: URL) -> Bool? { nil }

    var captureSampleRate: Int { 16000 }

    func prepareForDictation() async {}
    var benefitsFromWarmupClip: Bool { true }

    var supportsSampleInput: Bool { false }
    // Never reached in practice — the controller only calls this when supportsSampleInput is true, and
    // every such engine overrides it. Present so the WAV-only engines satisfy the protocol.
    func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String {
        throw SpeechEngineError.sampleInputUnsupported
    }
}

public enum SpeechEngineError: Error, Equatable {
    case unknownEngine(String)
    case sampleInputUnsupported
}

public final class SpeechEngineProvider: @unchecked Sendable {
    private let engines: [String: any SpeechEngine]
    private var activeId: String

    public init(engines: [any SpeechEngine], activeId: String) throws {
        var map: [String: any SpeechEngine] = [:]
        for e in engines { map[e.id] = e }
        guard map[activeId] != nil else { throw SpeechEngineError.unknownEngine(activeId) }
        self.engines = map
        self.activeId = activeId
    }

    public var active: any SpeechEngine { engines[activeId]! }

    public func engine(_ id: String) -> (any SpeechEngine)? { engines[id] }

    public func setActive(_ id: String) throws {
        guard engines[id] != nil else { throw SpeechEngineError.unknownEngine(id) }
        activeId = id
    }
}
