import Foundation

public struct ConfigSnapshot: Equatable, Sendable {
    public var stamps: [String: String]
    public init(stamps: [String: String] = [:]) { self.stamps = stamps }
}

// Stat-only (size:mtime) fingerprint of the config tree, keyed by path relative to the support dir. Uses
// the SAME first-level exclusions as ConfigWatchFilter so snapshot and watcher agree on what is config.
public enum ConfigTreeSnapshot {
    public static func stamp(of url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) != .typeDirectory else { return nil }
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(mtime)"
    }

    public static func relativeKey(for url: URL, supportDir: URL) -> String {
        let base = supportDir.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return path }
        return String(path.dropFirst(base.count).drop { $0 == "/" })
    }

    public static func capture(supportDir: URL) -> ConfigSnapshot {
        var stamps: [String: String] = [:]
        walk(dir: supportDir, supportDir: supportDir, topLevel: true, into: &stamps)
        return ConfigSnapshot(stamps: stamps)
    }

    private static func walk(dir: URL, supportDir: URL, topLevel: Bool, into stamps: inout [String: String]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if topLevel, ConfigWatchFilter.ignoredSubdirectories.contains(entry.lastPathComponent) { continue }
                walk(dir: entry, supportDir: supportDir, topLevel: false, into: &stamps)
            } else if let stamp = stamp(of: entry) {
                stamps[relativeKey(for: entry, supportDir: supportDir)] = stamp
            }
        }
    }
}

// Suppresses the FSEvents echo of the app's own config writes: each in-app write records its file's stamp;
// the watcher reloads only when the tree differs. Recording is per-file (never a whole-tree recapture) and
// shouldReload never mutates the baseline, so a concurrent external edit to a different file is never
// silently swallowed. Thread-safe via NSLock (watcher off-main, writers on the main actor).
public final class ConfigSelfWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var baseline: ConfigSnapshot

    public init(baseline: ConfigSnapshot = .init()) { self.baseline = baseline }

    // `stamp == nil` records a delete/rename source (its key is dropped).
    public func recordSelfWrite(relativePath: String, stamp: String?) {
        lock.withLock { baseline.stamps[relativePath] = stamp }
    }

    public func recordSelfWrite(url: URL, supportDir: URL) {
        recordSelfWrite(
            relativePath: ConfigTreeSnapshot.relativeKey(for: url, supportDir: supportDir),
            stamp: ConfigTreeSnapshot.stamp(of: url))
    }

    public func shouldReload(current: ConfigSnapshot) -> Bool {
        lock.withLock { current != baseline }
    }

    public func adopt(_ snapshot: ConfigSnapshot) {
        lock.withLock { baseline = snapshot }
    }

    public func baselineSnapshot() -> ConfigSnapshot {
        lock.withLock { baseline }
    }
}
