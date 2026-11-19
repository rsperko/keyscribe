public enum CodexPaneTitle {
    public static let shownLength = 29

    public static func thread(in title: String, among ids: [String]) -> String? {
        let words = title.split(whereSeparator: { $0.isWhitespace || $0 == "|" })
        let shown = ids.filter { id in id.count >= shownLength && words.contains { $0.hasPrefix(id.prefix(shownLength)) } }
        return Set(shown).count == 1 ? shown[0] : nil
    }
}
