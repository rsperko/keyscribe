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

    public static func todayString(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
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
    // so a paged list never materializes older days. Files are memory-mapped and parsed line-by-line
    // (no whole-file String, no all-substrings split) to bound peak memory. Malformed lines (e.g.
    // written by a future schema) are skipped, not fatal.
    public func entries(limit: Int? = nil) -> [HistoryEntry] {
        var all: [HistoryEntry] = []
        for file in dayFiles().reversed() {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file), options: .mappedIfSafe)
            else { continue }
            var day: [HistoryEntry] = []
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let entry = try? HistoryEntry(jsonLine: String(decoding: line, as: UTF8.self)) {
                    day.append(entry)
                }
            }
            day.sort { $0.timestamp > $1.timestamp }
            all.append(contentsOf: day)
            if let limit, all.count >= limit { return Array(all.prefix(limit)) }
        }
        return all
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
