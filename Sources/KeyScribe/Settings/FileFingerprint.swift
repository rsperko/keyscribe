import Foundation

// Cheap on-disk fingerprint (size + mtime, no content read) used by Settings models to skip a full
// re-decode when nothing on disk changed since the last load. Stat-only, so it costs far less than the
// TOML/markdown decode it guards.
enum FileFingerprint {
    static func file(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(mtime)"
    }

    static func dir(_ url: URL) -> String {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return "∅" }
        return names.sorted().map { "\($0)/\(file(url.appendingPathComponent($0)))" }.joined(separator: ",")
    }
}
