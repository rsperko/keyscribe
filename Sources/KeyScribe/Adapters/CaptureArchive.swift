import Foundation
import os

// Opt-in debug hook: when `KEYSCRIBE_KEEP_CAPTURE=<dir>` is set, a copy of each committed capture WAV is
// saved to <dir> before the pipeline deletes it. The WAV normally lives for milliseconds (record →
// transcribe → delete), so this enables offline analysis (glitch/SINAD scoring, waveform inspection) and lets
// `--capture-probe` keep its recordings. Off unless the env var is set.
enum CaptureArchive {
    static var keepDir: URL? {
        // getenv (not ProcessInfo.environment, which snapshots at first access) so a runtime setenv from the
        // `--keep-capture` flag is honored as well as an inherited env var.
        guard let c = getenv("KEYSCRIBE_KEEP_CAPTURE") else { return nil }
        let path = String(cString: c)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // Copy `url` into the keep dir (no-op unless the env var is set). `tag` prefixes the saved name so commit
    // vs probe captures are distinguishable; the source name already carries a UUID for uniqueness.
    static func archive(_ url: URL, tag: String) {
        guard let dir = keepDir else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(tag)-\(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            Log.audio.debug("archived capture → \(dest.path, privacy: .public)")
        } catch {
            Log.audio.error("capture archive failed: \(String(describing: error), privacy: .public)")
        }
    }
}
