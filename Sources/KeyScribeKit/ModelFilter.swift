import Foundation

public enum ModelFilter {
    public static func filter(_ models: [String], query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(q) }
    }
}
