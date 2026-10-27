import Foundation

// One dictation, every recorded field verbatim, plus the install summary — what a user sends when a
// dictation did not work. It deliberately carries what they said; the warning heads the text so it
// travels with every paste of it.
public enum SupportReport {
    public static let warning = """
        This report includes what you said, the text that was inserted, and for an AI mode the full AI request \
        and reply, which can hold text you selected or text from the app you were typing in. Remove anything \
        private before sending it.
        """

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static func render(entry: HistoryEntry, appName: String, setup: String) -> String {
        let json = (try? encoder.encode(entry)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let notes = notes(for: entry)
        return """
            \(appName) support report
            \(warning)

            Dictation
            \(json)
            \(notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n") + "\n")
            \(setup)
            """
    }

    // The shortcut trace is Phase A only; a spoken phrase can still move the dictation to another mode, which
    // would otherwise read as the trace contradicting `mode`.
    private static func notes(for entry: HistoryEntry) -> [String] {
        var notes: [String] = []
        if entry.shortcutCandidates != nil {
            notes.append("shortcut_candidates shows the mode the shortcut picked before anything was said.")
        }
        if entry.modeChoice == .spokenPhrase, let phrase = entry.routedPhrase {
            notes.append("The spoken phrase \u{201C}\(phrase)\u{201D} then switched to \(entry.modeName).")
        }
        return notes
    }
}
