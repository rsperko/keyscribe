import Foundation

// Durable, on-disk record of STT model load failures — os.Logger doesn't reliably surface on every machine
// and history records only successes, so a transient cold-load failure is otherwise undiagnosable. Holds
// only the model/file/compile error, never a transcript or token→original material, so it does not violate
// the speech-is-never-stored invariant. Pure here (formatting + trim-on-append cap); file IO is an adapter.
public enum ModelLoadDiagnostics {
    public static let maxEntries = 50

    public static func line(
        timestamp: String, engineId: String, timedOut: Bool, error: String
    ) -> String {
        let kind = timedOut ? "timeout" : "error"
        let flat = error.replacingOccurrences(of: "\n", with: " ")
        return "\(timestamp)\t\(engineId)\t\(kind)\t\(flat)"
    }

    public static func appended(existing: String, line: String, maxEntries: Int = maxEntries) -> String {
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.append(line)
        if lines.count > maxEntries { lines = Array(lines.suffix(maxEntries)) }
        return lines.joined(separator: "\n") + "\n"
    }
}
