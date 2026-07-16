import Darwin
import Foundation
import KeyScribeKit
import os

// Opt-in debug hook: a copy of each committed capture WAV is saved before the pipeline deletes it (the WAV
// normally lives only record→transcribe→delete). Enables offline analysis (glitch/SINAD scoring, waveform
// inspection) and lets `--capture-probe` keep its recordings.
//
// Two ways in, and they differ in retention. `KEYSCRIBE_KEEP_CAPTURE=<dir>` (or `--keep-capture <dir>`)
// names an arbitrary directory and is NEVER pruned — deleting files in a directory the user chose is not
// ours to do. `[audio] keep_captures` archives into the app-owned per-variant `captureArchiveDir`, pruned
// oldest-first to `keep_captures_max_mb`. The env var wins when both are set.
enum CaptureArchive {
    private struct Config {
        let dir: URL
        let maxBytes: Int64
    }

    // Written on main (launch + settings change), read on AudioCapture's controlQueue.
    private static let configured = OSAllocatedUnfairLock<Config?>(initialState: nil)

    // Pruning stats a directory, so it never runs on the commit path the pipeline awaits.
    private static let retentionQueue = DispatchQueue(label: "com.keyscribe.captures.retention", qos: .utility)

    private static var envDir: URL? {
        // getenv (not ProcessInfo.environment, which snapshots at first access) so a runtime setenv from the
        // `--keep-capture` flag is honored as well as an inherited env var.
        guard let c = getenv("KEYSCRIBE_KEEP_CAPTURE") else { return nil }
        let path = String(cString: c)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var keepDir: URL? {
        envDir ?? configured.withLock { $0?.dir }
    }

    static func publish(_ audio: Settings.Audio) {
        let config = audio.keepCaptures
            ? Config(dir: KeyScribePaths.captureArchiveDir, maxBytes: audio.keepCapturesMaxBytes)
            : nil
        configured.withLock { $0 = config }
    }

    // No-op unless retention is on. `tag` prefixes the saved name so commit vs probe captures are
    // distinguishable; the source name already carries a UUID for uniqueness.
    static func archive(_ url: URL, tag: String) {
        guard let dir = keepDir else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(tag)-\(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: dest)
            // Clone, don't copy: this runs inline on the commit path the pipeline awaits before transcribing,
            // and a clone is a metadata-only COW share (microseconds, no bytes written, source mtime preserved
            // as the sort key) instead of a real copy of a multi-MB WAV.
            //
            // CLONE_FORCE rather than CLONE so the fallback is OURS to see: CLONE would quietly degrade to a
            // full copy when cloning is impossible (a KEYSCRIBE_KEEP_CAPTURE dir on another volume or a
            // non-APFS filesystem) and we'd never know we were paying a byte copy in front of transcription.
            // We still take that copy rather than skip — it is exactly what this feature did before cloning,
            // and `--capture-probe` DELETES its working file trusting the archive, so skipping would destroy
            // the recording it was run to produce. Loud, not lossy.
            if copyfile(url.path, dest.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) != 0 {
                Log.audio.warning(
                    "capture archive cannot clone into \(dir.path, privacy: .public) (errno \(errno, privacy: .public)) — falling back to a full copy, which delays transcription by the copy time. Archive to a directory on the startup volume to avoid it.")
                try FileManager.default.copyItem(at: url, to: dest)
            }
            Log.audio.debug("archived capture → \(dest.path, privacy: .public)")
        } catch {
            Log.audio.error("capture archive failed: \(String(describing: error), privacy: .public)")
        }
        applyRetention()
    }

    // Prunes the app-owned archive to its budget, oldest first. Safe to call at any time; serialized on
    // retentionQueue so a burst of dictations can't race two sweeps against each other.
    static func applyRetention() {
        guard let config = configured.withLock({ $0 }), envDir == nil else { return }
        retentionQueue.async {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            guard let entries = try? fm.contentsOfDirectory(
                at: config.dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { return }
            let files: [CaptureRetention.File] = entries.compactMap { url in
                guard url.pathExtension == "wav",
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let bytes = values.fileSize, let modified = values.contentModificationDate
                else { return nil }
                return CaptureRetention.File(name: url.lastPathComponent, bytes: Int64(bytes), modified: modified)
            }
            for name in CaptureRetention.expired(files: files, maxBytes: config.maxBytes) {
                try? fm.removeItem(at: config.dir.appendingPathComponent(name))
            }
        }
    }
}
