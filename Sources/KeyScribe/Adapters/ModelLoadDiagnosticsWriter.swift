import Foundation
import KeyScribeKit

// Thin file sink over the pure ModelLoadDiagnostics formatter. Best-effort and append-only (capped):
// a write failure must never compound a load failure. Holds only the model/file/compile error, never
// any transcript — safe to persist (see ModelLoadDiagnostics).
enum ModelLoadDiagnosticsWriter {
    static func record(
        engineId: String, timedOut: Bool, error: String,
        to file: URL = KeyScribePaths.modelLoadDiagFile
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = ModelLoadDiagnostics.line(
            timestamp: timestamp, engineId: engineId, timedOut: timedOut, error: error)
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let out = ModelLoadDiagnostics.appended(existing: existing, line: line)
        try? out.write(to: file, atomically: true, encoding: .utf8)
    }
}
