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

    // True when the engine can consume audio incrementally during capture and produce the transcript at
    // commit with less post-release latency (streaming). Default false; streaming-capable engines override
    // it. The controller only calls makeStreamingSession when this is true AND the streaming flag is on;
    // every other engine and the flag-off path stay on the batch transcribe above, unchanged.
    var supportsStreaming: Bool { get }
    // Open a streaming session bound to this engine for one dictation. `sampleRate` is the engine's
    // captureSampleRate; `biasTerms` is the recognition bias for the session's lifetime. The session holds
    // the engine's non-Sendable handle until finalizeTranscript/cancel, so the decorator keeps its
    // exclusive lock for that whole span. Only called when supportsStreaming is true.
    func makeStreamingSession(sampleRate: Int, biasTerms: [String]) async throws -> any StreamingSpeechSession

    func evict() async

    // Preheat any per-dictation session state at press so it overlaps speech; fire-and-forget, default
    // no-op. Only Apple's one-shot SpeechAnalyzer needs it today.
    func prepareForDictation() async

    // Pre-build any per-term-set bias artifacts (Parakeet's CTC vocab/rescorer) once per residency at warm
    // time, so the first biased dictation in a mode with local dictionary terms doesn't build them
    // mid-transcription. Called from the warm task with every enabled mode's bias set. Default no-op;
    // only Parakeet overrides. Best-effort — a warm failure never fails the load.
    func prewarmBias(termSets: [[String]]) async

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
    func prewarmBias(termSets: [[String]]) async {}
    var benefitsFromWarmupClip: Bool { true }

    var supportsSampleInput: Bool { false }
    // Never reached in practice — the controller only calls this when supportsSampleInput is true, and
    // every such engine overrides it. Present so the WAV-only engines satisfy the protocol.
    func transcribe(samples: [Float], sampleRate: Int, biasTerms: [String]) async throws -> String {
        throw SpeechEngineError.sampleInputUnsupported
    }

    var supportsStreaming: Bool { false }
    // Never reached in practice — the controller only calls this when supportsStreaming is true. Present so
    // the batch-only engines satisfy the protocol; the same silent-no-op trap as transcribe(samples:).
    func makeStreamingSession(sampleRate: Int, biasTerms: [String]) async throws -> any StreamingSpeechSession {
        throw SpeechEngineError.streamingUnsupported
    }
}

// One dictation's incremental transcription. Created by makeStreamingSession, fed decoded PCM off the
// realtime path as capture proceeds, and closed exactly once at commit (finalizeTranscript) or abort
// (cancel). Every exit path must be reached exactly once so the decorator's exclusive lock is always
// released; a leaked session wedges the engine until relaunch (SerializedEngine holds its lock for the
// session's whole lifetime).
//
// Contract: append/finalizeTranscript MUST run their inference off the main actor. The controller awaits
// finalizeTranscript from the @MainActor commit task, so if an implementation did heavy work on the main
// actor the HUD would freeze during the post-release finalize — the main actor must only suspend here.
public protocol StreamingSpeechSession: Sendable {
    // Feed the next decoded mono Float32 chunk (engine sample rate). Called off the writer/RT threads.
    // Throws if the chunk cannot be admitted (e.g. a failed resample); the driver then cancels the session
    // and the dictation degrades to a batch transcribe of the intact accumulated audio, so audio a user
    // spoke is never silently dropped mid-utterance.
    func append(samples: [Float]) async throws
    // Run the final chunk and return the whole transcript. Terminal: the session is spent after this.
    func finalizeTranscript() async throws -> String
    // Abort without a result (ESC/over-limit). Terminal: releases SDK state, no transcript.
    func cancel() async
}

public enum SpeechEngineError: Error, Equatable {
    case unknownEngine(String)
    case sampleInputUnsupported
    case streamingUnsupported
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
