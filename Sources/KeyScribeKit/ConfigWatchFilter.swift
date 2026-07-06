import Foundation

// Whether a changed file under the watched support dir should trigger a config reload. The FSEvents
// watcher observes the whole tree, but some subtrees are NOT config and must never invalidate the
// ConfigCache: `history/` (a JSONL append every dictation), `lkg/` (last-known-good mirrors), `models/`.
// Without this filter every dictation re-reads all config, recompiles stages, and rebuilds the hotkey
// monitor, defeating "a normal dictation does zero config I/O".
public enum ConfigWatchFilter {
    public static let ignoredSubdirectories: Set<String> = ["history", "lkg", "models"]

    // True if a change at `changedPath` (absolute) is relevant to configuration, given the watched
    // `supportDir` (absolute). A path under an ignored first-level subdirectory is not relevant.
    // Paths that don't resolve under the support dir are treated as relevant (fail safe: reload).
    public static func isConfigRelevant(changedPath: String, supportDir: String) -> Bool {
        let base = normalize(supportDir)
        let path = normalize(changedPath)
        guard path == base || path.hasPrefix(base + "/") else { return true }
        let relative = path.dropFirst(base.count).drop { $0 == "/" }
        guard let first = relative.split(separator: "/").first else { return true }
        return !ignoredSubdirectories.contains(String(first))
    }

    // True if ANY changed path in a coalesced FSEvents batch is config-relevant.
    public static func batchIsConfigRelevant(changedPaths: [String], supportDir: String) -> Bool {
        changedPaths.contains { isConfigRelevant(changedPath: $0, supportDir: supportDir) }
    }

    // FSEvents resolves firmlinked prefixes (/var, /tmp → /private/...) while a FileManager URL keeps the
    // unresolved form; strip /private from both so a temp-dir support path compares equal. Drop trailing slash.
    private static func normalize(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("/private/") { s.removeFirst("/private".count) }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
