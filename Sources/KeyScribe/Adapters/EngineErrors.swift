import Foundation

// Shared engine errors, replacing the per-adapter Whisper/Qwen3/Moonshine error enums.
enum EngineError: Error {
    case notInitialized
    case badModelURL(String)
    case audioDecodeFailed
}

// The requested engine id isn't constructible in this build (no descriptor / not wired).
enum EngineUnavailable: Error, CustomStringConvertible {
    case notWired(String)
    var description: String {
        switch self {
        case .notWired(let name): return "\(name) isn't available in this build yet."
        }
    }
}
