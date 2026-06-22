import Foundation

// Pure search over locally stored text (ui_design.md §8): case-insensitive substring over the
// heard transcription, the final result, and the mode name. An empty query returns everything.
public enum HistorySearch {
    public static func filter(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { matches($0, trimmedQuery: q) }
    }

    public static func matches(_ entry: HistoryEntry, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return matches(entry, trimmedQuery: q)
    }

    private static func matches(_ entry: HistoryEntry, trimmedQuery q: String) -> Bool {
        entry.heard.localizedCaseInsensitiveContains(q)
            || entry.result.localizedCaseInsensitiveContains(q)
            || entry.modeName.localizedCaseInsensitiveContains(q)
    }
}
