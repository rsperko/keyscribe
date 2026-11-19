import Foundation

public enum OpencodePaneTitle {
    static let marker = "OC | "
    static let home = "OpenCode"

    public static func showsHome(_ title: String) -> Bool {
        title.trimmingCharacters(in: .whitespaces) == home
    }

    public static func session(in title: String, among sessions: [OpencodeSession]) -> String? {
        let start = title.drop { !$0.isLetter && !$0.isNumber }
        guard start.hasPrefix(marker) else { return nil }
        let shown = start.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        guard !shown.isEmpty else { return nil }
        let matching: [OpencodeSession]
        if let cut = shortened(shown) {
            matching = sessions.filter { $0.shownTitle?.hasPrefix(cut) == true }
        } else {
            matching = sessions.filter { $0.shownTitle == shown }
        }
        return matching.count == 1 ? matching[0].id : nil
    }

    private static func shortened(_ shown: String) -> String? {
        for ellipsis in ["\u{2026}", "..."] where shown.hasSuffix(ellipsis) {
            let cut = String(shown.dropLast(ellipsis.count)).trimmingCharacters(in: .whitespaces)
            return cut.isEmpty ? nil : cut
        }
        return nil
    }
}
