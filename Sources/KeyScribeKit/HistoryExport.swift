import Foundation

// Pure export of locally stored history to a user-chosen text artifact (ui_design.md §8). Derives
// entirely from the on-disk entries the user already has — it reads nothing hidden and writes nothing;
// the NSSavePanel the app shows is the consent. Day/time formatting is injected so the export matches
// whatever the History window displays and the tests stay locale/timezone-independent.
public enum HistoryExport {
    public enum Format: String, CaseIterable, Sendable {
        case text, markdown, json

        public var fileExtension: String {
            switch self {
            case .text: "txt"
            case .markdown: "md"
            case .json: "jsonl"
            }
        }
    }

    // Injected day/time rendering (not Sendable — built and consumed in one context).
    public struct Formatting {
        public let day: (Date) -> String
        public let time: (Date) -> String
        public init(day: @escaping (Date) -> String, time: @escaping (Date) -> String) {
            self.day = day
            self.time = time
        }
    }

    // Owns its own encoder rather than reaching into HistoryEntry's private one — same config so each
    // line is byte-identical to the on-disk JSONL and round-trips through HistoryEntry(jsonLine:).
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static func export(_ entries: [HistoryEntry], format: Format, formatting: Formatting, appName: String) -> String {
        switch format {
        case .json: return json(entries)
        case .markdown: return markdown(entries, formatting, appName)
        case .text: return text(entries, formatting, appName)
        }
    }

    private static func json(_ entries: [HistoryEntry]) -> String {
        entries.compactMap { try? String(decoding: encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
    }

    private static func markdown(_ entries: [HistoryEntry], _ f: Formatting, _ appName: String) -> String {
        var out = "# \(appName) history\n"
        for group in grouped(entries, f) {
            out += "\n## \(group.day)\n\n"
            for e in group.entries {
                let labels = e.dataBoundaryLabels.joined(separator: ", ")
                out += "- **\(f.time(e.timestamp))** · \(e.modeName) · \(label(e.outcome))"
                if !labels.isEmpty { out += " · \(labels)" }
                out += "\n"
                if !e.heard.isEmpty, e.heard != e.result { out += "  - Heard: \(e.heard)\n" }
                out += "  - Result: \(e.result.isEmpty ? "(no text)" : e.result)\n"
            }
        }
        return out
    }

    private static func text(_ entries: [HistoryEntry], _ f: Formatting, _ appName: String) -> String {
        var out = "\(appName) history\n"
        for group in grouped(entries, f) {
            out += "\n\(group.day)\n"
            for e in group.entries {
                let labels = e.dataBoundaryLabels.joined(separator: ", ")
                out += "  \(f.time(e.timestamp))  \(e.modeName) · \(label(e.outcome))"
                if !labels.isEmpty { out += "  [\(labels)]" }
                out += "\n"
                if !e.heard.isEmpty, e.heard != e.result { out += "    Heard:  \(e.heard)\n" }
                out += "    Result: \(e.result.isEmpty ? "(no text)" : e.result)\n"
            }
        }
        return out
    }

    // Group by day key, preserving the input order (newest-first from the store) both across days and
    // within each day.
    private static func grouped(_ entries: [HistoryEntry], _ f: Formatting) -> [(day: String, entries: [HistoryEntry])] {
        var order: [String] = []
        var map: [String: [HistoryEntry]] = [:]
        for e in entries {
            let key = f.day(e.timestamp)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(e)
        }
        return order.map { (day: $0, entries: map[$0] ?? []) }
    }

    private static func label(_ outcome: HistoryEntry.Outcome) -> String {
        switch outcome {
        case .inserted: "Inserted"
        case .copied: "Copied instead of inserted"
        case .localFallback: "Local fallback"
        case .failed: "Failed"
        }
    }
}

// Pure local aggregates over stored history (ui_design.md §8). No clock — every date comes from the
// entries; derived entirely from what is already on disk, never from hidden telemetry or logs.
public struct HistoryStats: Equatable, Sendable {
    public var total: Int
    public var byMode: [String: Int]
    public var byOutcome: [HistoryEntry.Outcome: Int]
    public var cloudCount: Int
    public var localCount: Int
    public var redactionCount: Int
    public var wordsDictated: Int
    public var firstTimestamp: Date?
    public var lastTimestamp: Date?

    public var redactionRate: Double { total == 0 ? 0 : Double(redactionCount) / Double(total) }

    public static func compute(from entries: [HistoryEntry]) -> HistoryStats {
        var byMode: [String: Int] = [:]
        var byOutcome: [HistoryEntry.Outcome: Int] = [:]
        var cloud = 0, redaction = 0, words = 0
        var first: Date?, last: Date?
        for e in entries {
            byMode[e.modeName, default: 0] += 1
            byOutcome[e.outcome, default: 0] += 1
            if e.cloudInvolved { cloud += 1 }
            if e.redaction { redaction += 1 }
            words += e.result.split(whereSeparator: \.isWhitespace).count
            first = first.map { Swift.min($0, e.timestamp) } ?? e.timestamp
            last = last.map { Swift.max($0, e.timestamp) } ?? e.timestamp
        }
        return HistoryStats(
            total: entries.count, byMode: byMode, byOutcome: byOutcome,
            cloudCount: cloud, localCount: entries.count - cloud, redactionCount: redaction,
            wordsDictated: words, firstTimestamp: first, lastTimestamp: last)
    }
}
