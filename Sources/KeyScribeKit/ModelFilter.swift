import Foundation

// Pure substring filter for the model-selection combo box: case-insensitive, whitespace-trimmed.
// An empty query returns every model, order preserved.
public enum ModelFilter {
    public static func filter(_ models: [String], query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(q) }
    }
}
