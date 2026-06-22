import Foundation

// Pure search over locally stored text (ui_design.md §8): case-insensitive substring over the
// heard transcription, the final result, and the mode name. An empty query returns everything.
public enum HistorySearch {
    public static func filter(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.heard.localizedCaseInsensitiveContains(q)
                || $0.result.localizedCaseInsensitiveContains(q)
                || $0.modeName.localizedCaseInsensitiveContains(q)
        }
    }
}
