import Foundation

public protocol SpeechEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportsRecognitionBias: Bool { get }
    // Sample rate (Hz) the capture path should record at for this engine, so the WAV needs no
    // resample before transcription. 16 kHz suits every engine except Qwen3-ASR (24 kHz).
    var captureSampleRate: Int { get }
    func loadIfNeeded() async throws
    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String
    func evict() async

    // Install footprint owned by this engine, used by reconcile/delete. The subdirectory names
    // (under modelsDir) the engine downloads into; empty for system-managed engines.
    // `verifyInstalled` reports whether those files are confirmed on disk: `true`/`false` when the
    // SDK can check integrity, `nil` ("can't verify") to defer to the install marker rather than risk
    // deleting a valid install. Only Parakeet can verify; the rest return the default `nil`.
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
}

public enum SpeechEngineError: Error, Equatable {
    case unknownEngine(String)
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
