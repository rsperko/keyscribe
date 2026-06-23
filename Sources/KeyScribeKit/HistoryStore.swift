import Foundation

// Append-only local history: a `history/` directory with one JSONL file per day (design.md §4.7,
// §5). Like the other config stores this lives in KeyScribeKit and does its own FileManager I/O; the
// only OS edge is the wall clock, isolated to `todayString`. Day boundaries follow the user's local
// calendar so an entry lands in the day they spoke it.
public struct HistoryStore: Sendable {
    public let dir: URL

    public init(supportDir: URL) {
        dir = supportDir.appendingPathComponent("history", isDirectory: true)
    }

    // Configured once and only ever read — DateFormatter is thread-safe for formatting when not
    // mutated, so a shared instance avoids allocating one per append.
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
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(today).jsonl")
        let line = Data((try entry.jsonLine() + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: file.path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: file)
        }
    }

    public func dayFiles() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.filter { $0.hasSuffix(".jsonl") }.sorted()
    }

    // Cheap fingerprint of the history's current state (file count + the latest day file's name, size,
    // and mtime). Appends always land in the latest day file and retention deletes whole files, so this
    // changes whenever the entries do — letting a viewer skip a full re-parse when nothing has changed.
    public func signature() -> String {
        let files = dayFiles()
        guard let latest = files.last else { return "empty" }
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent(latest).path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(files.count)|\(latest)|\(size)|\(mtime)"
    }

    // Newest entry first. Reads day files newest-first and stops once `limit` entries are collected,
    // so a paged list never materializes older days. Within a day, lines are appended chronologically,
    // so we scan the mapped bytes backward for newlines and decode only the last `limit` lines — a
    // high-volume current day no longer splits the whole file into a per-line slice array just to keep
    // the last page. Files are memory-mapped; malformed lines (e.g. a future schema) are skipped, not
    // fatal, and do not consume a page slot.
    public func entries(limit: Int? = nil) -> [HistoryEntry] {
        var all: [HistoryEntry] = []
        for file in dayFiles().reversed() {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file), options: .mappedIfSafe)
            else { continue }
            let remaining = limit.map { max(0, $0 - all.count) }
            let day = Self.lastLines(data, limit: remaining).sorted { $0.timestamp > $1.timestamp }
            all.append(contentsOf: day)
            if let limit, all.count >= limit { return Array(all.prefix(limit)) }
        }
        return all
    }

    // Decode up to `limit` entries from the end of a JSONL day file, newest first, by walking the
    // mapped bytes backward newline to newline — no whole-file slice array, no String per skipped line.
    private static func lastLines(_ data: Data, limit: Int?) -> [HistoryEntry] {
        var entries: [HistoryEntry] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var end = bytes.count
            while end > 0 {
                if let limit, entries.count >= limit { return }
                var start = end
                while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
                if end > start,
                   let entry = try? HistoryEntry(jsonLine: String(decoding: bytes[start..<end], as: UTF8.self)) {
                    entries.append(entry)
                }
                end = start - 1
            }
        }
        return entries
    }

    // Remove a single entry by rewriting the one day file that holds it, dropping every line that
    // decodes to an equal entry (entries carry no id, so full-value equality is the key). Malformed
    // or future-schema lines never match and are preserved. The day file is deleted outright when it
    // empties, so `dayFiles()`/`signature()` stay consistent. Returns whether anything was removed.
    @discardableResult
    public func delete(_ entry: HistoryEntry) -> Bool {
        for file in dayFiles() {
            let url = dir.appendingPathComponent(file)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var kept: [String] = []
            var removed = false
            for line in content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                if let decoded = try? HistoryEntry(jsonLine: line), decoded == entry {
                    removed = true
                } else {
                    kept.append(line)
                }
            }
            guard removed else { continue }
            if kept.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try? Data((kept.joined(separator: "\n") + "\n").utf8).write(to: url)
            }
            return true
        }
        return false
    }

    @discardableResult
    public func applyRetention(today: String = HistoryStore.todayString(), retentionDays: Int) -> [String] {
        let expired = HistoryRetention.expired(dayFiles: dayFiles(), today: today, retentionDays: retentionDays)
        for file in expired {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
        return expired
    }
}
