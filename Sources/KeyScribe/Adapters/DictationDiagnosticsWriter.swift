import Foundation
import KeyScribeKit

// Thin file sink for the textless per-dictation trace. Best-effort, append-only, ring-buffered: one
// line per terminal dictation (success, no-speech, failure, timeout). The line is the DictationRecord
// `humanSummary()` — hashes/counts/ms and the cold-start idle/warm/deadline fields, never any transcript
// — so persisting it does not violate the speech-is-never-stored invariant. Reuses the ModelLoadDiagnostics
// ring-buffer cap so the file cannot grow without bound.
enum DictationDiagnosticsWriter {
    static let maxEntries = 500

    static func record(summary: String, at date: Date = Date(), to file: URL = KeyScribePaths.dictationDiagFile) {
        let timestamp = ISO8601DateFormatter().string(from: date)
        let line = "\(timestamp)\t\(summary.replacingOccurrences(of: "\n", with: " "))"
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let out = ModelLoadDiagnostics.appended(existing: existing, line: line, maxEntries: maxEntries)
        try? out.write(to: file, atomically: true, encoding: .utf8)
    }
}
