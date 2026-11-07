import Foundation
import KeyScribeKit

final class ClaudeTranscriptTitles: @unchecked Sendable {
    static let tailBytes = 256 * 1024
    static let rereadInterval: TimeInterval = 10

    private struct Cached {
        var url: URL
        var modified: Date
        var readAt: Date
        var titles: ClaudeTranscriptTitle
    }

    private let configDirs: [URL]
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cache: [String: Cached] = [:]
    private var misses: [String: Date] = [:]

    init(configDirs: [URL], now: @escaping @Sendable () -> Date = Date.init) {
        self.configDirs = configDirs
        self.now = now
    }

    func title(for entry: ClaudeRegistryEntry) -> String? {
        titles(for: entry).displayTitle
    }

    func titles(for entry: ClaudeRegistryEntry, rereading: Bool = true) -> ClaudeTranscriptTitle {
        lock.withLock { read(entry, rereading: rereading) }
    }

    private func read(_ entry: ClaudeRegistryEntry, rereading: Bool) -> ClaudeTranscriptTitle {
        if !rereading {
            if let cached = cache[entry.sessionId] { return cached.titles }
            if misses[entry.sessionId] != nil { return .init() }
        }
        guard let url = cache[entry.sessionId]?.url ?? lookUp(entry), let modified = Self.modified(url) else { return .init() }
        if let cached = cache[entry.sessionId], cached.url == url,
           cached.modified == modified || now().timeIntervalSince(cached.readAt) < Self.rereadInterval {
            return cached.titles
        }
        let titles = Self.readTail(url).map { ClaudeTranscriptTitle.parse(in: $0.data, startsMidLine: $0.cut) } ?? .init()
        cache[entry.sessionId] = Cached(url: url, modified: modified, readAt: now(), titles: titles)
        return titles
    }

    func forget(keeping sessions: Set<String>) {
        lock.withLock {
            cache = cache.filter { sessions.contains($0.key) }
            misses = misses.filter { sessions.contains($0.key) }
        }
    }

    private func lookUp(_ entry: ClaudeRegistryEntry) -> URL? {
        if let missed = misses[entry.sessionId], now().timeIntervalSince(missed) < Self.rereadInterval { return nil }
        guard let url = locate(entry) else {
            misses[entry.sessionId] = now()
            return nil
        }
        misses[entry.sessionId] = nil
        return url
    }

    private func locate(_ entry: ClaudeRegistryEntry) -> URL? {
        let file = "\(entry.sessionId).jsonl"
        let own = entry.configDir.map { [URL(fileURLWithPath: $0, isDirectory: true)] } ?? []
        for dir in own + configDirs.filter({ $0.path != entry.configDir }) {
            let projects = dir.appendingPathComponent("projects", isDirectory: true)
            let direct = projects.appendingPathComponent(ClaudeTranscriptTitle.projectFolder(for: entry.cwd)).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
            let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            if let found = folders.map({ $0.appendingPathComponent(file) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                return found
            }
        }
        return nil
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func readTail(_ url: URL) -> (data: Data, cut: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return (data, start > 0)
    }
}
