import Foundation

enum EngineError: Error {
    case notInitialized
    case badModelURL(String)
    case audioDecodeFailed
    case downloadFailed(String)
    // A streaming session failed mid-flight; the controller degrades to a batch transcribe of the audio.
    case streamingFailed
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
