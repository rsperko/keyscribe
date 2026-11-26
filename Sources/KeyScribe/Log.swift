import KeyScribeKit
import os

enum Log {
    static let bias = Logger(subsystem: "com.keyscribe.app", category: "bias")
    static let context = Logger(subsystem: "com.keyscribe.app", category: "context")
    static let models = Logger(subsystem: "com.keyscribe.app", category: "models")
    static let audio = Logger(subsystem: "com.keyscribe.app", category: "audio")
    static let insertion = Logger(subsystem: "com.keyscribe.app", category: "insertion")
    static let config = Logger(subsystem: "com.keyscribe.app", category: "config")
    static let agents = Logger(subsystem: "com.keyscribe.app", category: "agents")
    static let history = Logger(subsystem: "com.keyscribe.app", category: "history")
}

extension HistoryStore.RetentionSweep {
    func logFailures() {
        guard !succeeded else { return }
        Log.history.error(
            "history retention could not delete \(failed.count, privacy: .public) expired day(s) and could not list \(unreadable.count, privacy: .public) folder(s)")
    }
}
