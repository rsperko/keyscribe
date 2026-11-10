import Foundation

// Append-only local history: one JSONL file per local calendar day.
public struct HistoryStore: Sendable {
    public let dir: URL

    // Serializes append and delete-rewrite so a background append and main-actor delete cannot interleave.
    // HistoryStore is a value type shared by both writers, so the queue is a shared static.
    static let mutationQueue = DispatchQueue(label: "com.keyscribe.history.mutation")

    public init(supportDir: URL) {
        dir = supportDir.appendingPathComponent("history", isDirectory: true)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func todayString(date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    public func append(_ entry: HistoryEntry, today: String = HistoryStore.todayString()) throws {
        try Self.mutationQueue.sync {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(today).jsonl")
            var payload = try entry.jsonLine() + "\n"
            if let handle = FileHandle(forUpdatingAtPath: file.path) {
                defer { try? handle.close() }
                let end = try handle.seekToEnd()
                // Separate from a crash-truncated previous line before appending.
                if end > 0 {
                    try handle.seek(toOffset: end - 1)
                    if try handle.read(upToCount: 1) != Data([0x0A]) { payload = "\n" + payload }
                    try handle.seekToEnd()
                }
                try handle.write(contentsOf: Data(payload.utf8))
            } else {
                if FileManager.default.fileExists(atPath: file.path) {
                    throw CocoaError(.fileReadNoPermission)
                }
                try Data(payload.utf8).write(to: file)
            }
        }
    }

    public func dayFiles() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.filter { $0.hasSuffix(".jsonl") }.sorted()
    }

    // Cheap fingerprint for viewers that can skip a re-parse when history has not changed.
    public func signature() -> String {
        let files = dayFiles()
        guard let latest = files.last else { return "empty" }
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent(latest).path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(files.count)|\(latest)|\(size)|\(mtime)"
    }

    // Newest entry first; malformed lines are skipped and do not consume a page slot.
    public func entries(limit: Int? = nil, where kept: ((HistoryEntry) -> Bool)? = nil) -> [HistoryEntry] {
        var all: [HistoryEntry] = []
        for file in dayFiles().reversed() {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file), options: .mappedIfSafe)
            else { continue }
            let remaining = limit.map { max(0, $0 - all.count) }
            let day = Self.lastLines(data, limit: remaining, where: kept).sorted { $0.timestamp > $1.timestamp }
            all.append(contentsOf: day)
            if let limit, all.count >= limit { return Array(all.prefix(limit)) }
        }
        return all
    }

    // Walk a mapped JSONL day file backward so paging avoids whole-file line splitting.
    private static func lastLines(_ data: Data, limit: Int?, where kept: ((HistoryEntry) -> Bool)? = nil) -> [HistoryEntry] {
        var entries: [HistoryEntry] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var end = bytes.count
            while end > 0 {
                if let limit, entries.count >= limit { return }
                var start = end
                while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
                if end > start,
                   let entry = try? HistoryEntry(jsonLine: String(decoding: bytes[start..<end], as: UTF8.self)), kept?(entry) ?? true {
                    entries.append(entry)
                }
                end = start - 1
            }
        }
        return entries
    }

    // `notFound` (already gone) and `deleted` both satisfy the caller's intent; only `writeFailed` means
    // the entry is still on disk. Kept distinct so a privacy-motivated delete on a full disk or read-only
    // history dir cannot silently report success, while an already-removed row does not flash a false error.
    public enum DeleteOutcome: Sendable { case deleted, notFound, writeFailed }

    // Remove the first matching line only; duplicate entries can compare equal after JSON round-trip.
    @discardableResult
    public func delete(_ entry: HistoryEntry) -> DeleteOutcome {
        // Try the expected local-day file first, then fall back for rare day-boundary skew.
        let derived = "\(HistoryStore.todayString(date: entry.timestamp)).jsonl"
        var files = [derived]
        files.append(contentsOf: dayFiles().filter { $0 != derived })
        for file in files {
            switch deleteEntry(entry, fromFile: file) {
            case .deleted: return .deleted
            case .writeFailed: return .writeFailed
            case .notFound: continue
            }
        }
        return .notFound
    }

    // Rewrites the first matching line in place, keeping its position in the day file.
    @discardableResult
    public func replace(_ entry: HistoryEntry, with replacement: HistoryEntry) -> Bool {
        let entry = (try? HistoryEntry(jsonLine: entry.jsonLine())) ?? entry
        let derived = "\(HistoryStore.todayString(date: entry.timestamp)).jsonl"
        return ([derived] + dayFiles().filter { $0 != derived }).contains { rewrite(entry, with: replacement, inFile: $0) }
    }

    // `notFound` means no readable day file holds the entry; a file that could not be read or written makes it
    // `failed`, so an entry that is still on disk is never reported as gone.
    public enum UpdateOutcome: Sendable { case updated, notFound, failed }

    @discardableResult
    public func update(id: String, near date: Date, _ change: (HistoryEntry) -> HistoryEntry) -> UpdateOutcome {
        let derived = "\(HistoryStore.todayString(date: date)).jsonl"
        var failed = false
        for file in [derived] + dayFiles().filter({ $0 != derived }) {
            let outcome: UpdateOutcome = Self.mutationQueue.sync {
                let url = dir.appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: url.path) else { return .notFound }
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return .failed }
                var lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                guard let index = lines.firstIndex(where: { (try? HistoryEntry(jsonLine: $0))?.id == id }) else { return .notFound }
                guard let current = try? HistoryEntry(jsonLine: lines[index]),
                      let line = try? change(current).jsonLine() else { return .failed }
                lines[index] = line
                return (try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)) != nil
                    ? .updated : .failed
            }
            switch outcome {
            case .updated: return .updated
            case .failed: failed = true
            case .notFound: continue
            }
        }
        return failed ? .failed : .notFound
    }

    private func rewrite(_ entry: HistoryEntry, with replacement: HistoryEntry, inFile file: String) -> Bool {
        Self.mutationQueue.sync {
            let url = dir.appendingPathComponent(file)
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  let line = try? replacement.jsonLine() else { return false }
            var lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let index = lines.firstIndex(where: { (try? HistoryEntry(jsonLine: $0)) == entry }) else { return false }
            lines[index] = line
            return (try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)) != nil
        }
    }

    private static func isSameRecord(_ a: HistoryEntry, _ b: HistoryEntry) -> Bool {
        if let first = a.id, let second = b.id { return first == second }
        guard a.outcome.isCommand, b.outcome.isCommand else { return a == b }
        var a = a, b = b
        a.outcome = .command; a.failureReason = nil
        b.outcome = .command; b.failureReason = nil
        return a == b
    }

    private func deleteEntry(_ entry: HistoryEntry, fromFile file: String) -> DeleteOutcome {
        Self.mutationQueue.sync {
            let url = dir.appendingPathComponent(file)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return .notFound }
            var kept: [String] = []
            var removed = false
            for line in content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                if !removed, let decoded = try? HistoryEntry(jsonLine: line), Self.isSameRecord(decoded, entry) {
                    removed = true
                } else {
                    kept.append(line)
                }
            }
            guard removed else { return .notFound }
            do {
                if kept.isEmpty {
                    try FileManager.default.removeItem(at: url)
                } else {
                    try Data((kept.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
                }
            } catch {
                return .writeFailed
            }
            return .deleted
        }
    }

    @discardableResult
    public func applyRetention(today: String = HistoryStore.todayString(), retentionDays: Int) -> [String] {
        Self.mutationQueue.sync {
            let expired = HistoryRetention.expired(dayFiles: dayFiles(), today: today, retentionDays: retentionDays)
            for file in expired {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
            return expired
        }
    }
}
