import Foundation

public protocol SpeechEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportsRecognitionBias: Bool { get }
    // Capture sample rate (Hz), so the WAV needs no resample before transcription. 16 kHz for every
    // engine except Qwen3-ASR (24 kHz).
    var captureSampleRate: Int { get }
    // Contract: once install is complete (verifyInstalled true / install marker set), load must not re-fetch
    // model files. A cold load must not make network metadata checks (STT is always on-device); keep SDK
    // side caches offline where the SDK allows.
    func loadIfNeeded() async throws
    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String

    // True when the engine can transcribe already-decoded PCM directly, so the capture path hands it the
    // writer's samples instead of re-reading/decoding the WAV. Default false; Apple keeps the file (URL).
    var supportsSampleInput: Bool { get }
    // Transcribe mono Float32 PCM at `sampleRate` (captureSampleRate). Only called when supportsSampleInput
    // is true. `wavURL` is still written for archive/probe/fallback.
    func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String

    func evict() async

    // Preheat per-dictation session state at press so it overlaps speech; fire-and-forget, default no-op.
    // Only Apple's one-shot SpeechAnalyzer needs it today.
    func prepareForDictation() async

    // False for Apple: its analyzer is one-shot, so a warmup transcribe would consume the pair prepared for
    // the real dictation (prepareForDictation is its warmup instead).
    var benefitsFromWarmupClip: Bool { get }

    // Subdirectory names under modelsDir the engine downloads into (reconcile/delete); empty for
    // system-managed engines.
    var installDirNames: [String] { get }
    func verifyInstalled(in modelsDir: URL) -> Bool?
}

public extension SpeechEngine {
    // Default: no native progress, just load. Downloadable engines override to report byte/phase progress.
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
    // Never reached: the controller only calls this when supportsSampleInput is true. Present so WAV-only
    // engines satisfy the protocol.
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
