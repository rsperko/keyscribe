public enum CodexPaneTitle {
    public static let shownLength = 29

    public static func thread(in title: String, among ids: [String]) -> String? {
        let shown = ids.filter { $0.count >= shownLength && title.contains(String($0.prefix(shownLength))) }
        return Set(shown).count == 1 ? shown[0] : nil
    }
}
