import Foundation

public protocol SpeechEngine: Sendable {
    var id: String { get }
    var displayName: String { get }
    var supportsRecognitionBias: Bool { get }
    func loadIfNeeded() async throws
    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String
    func evict() async

    // Install footprint owned by this engine, used by reconcile/delete. The subdirectory names
    // (under modelsDir) the engine downloads into; empty for system-managed engines. `installState`
    // reports whether those files are verifiably on disk — engines whose SDK can't check integrity
    // return `.marker` to defer to the install marker rather than risk deleting a valid install.
    var installDirNames: [String] { get }
    func installState(in modelsDir: URL) -> EngineInstallState
}

// Whether an engine's model files are confirmed on disk. `.marker` means "can't verify — trust the
// install marker" (no SDK integrity check), used by Whisper/Qwen3/Moonshine.
public enum EngineInstallState: Sendable, Equatable {
    case present, absent, marker
}

public extension SpeechEngine {
    // Default: a download with no native progress just loads. Downloadable engines override to report
    // byte/phase progress.
    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws {
        try await loadIfNeeded()
    }

    // Defaults suit system-managed engines and any engine that defers to the install marker.
    var installDirNames: [String] { [] }
    func installState(in modelsDir: URL) -> EngineInstallState { .marker }
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
