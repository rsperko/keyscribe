import Foundation

enum EngineError: Error {
    case notInitialized
    case audioDecodeFailed
    case audioTooLong(seconds: Double, limit: Double)
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

struct AppleSpeechUnavailable: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
