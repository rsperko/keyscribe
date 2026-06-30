import Foundation

// What a History correction (replacement / dictionary term) is seeded from. The trigger must come from
// a selection in the *Heard* text: a replacement built from the LLM/result text would mangle every
// dictation that contains that phrase. A dictionary seed is the selected Heard word or phrase, falling
// back to a one-word result only. Pure so the rule is unit-tested away from the SwiftUI view.
public enum HistoryCorrectionSource {
    // The misheard fragment for a replacement — only when the selection is from the Heard text.
    public static func replacement(selection: String, selectionIsHeard: Bool) -> String {
        selectionIsHeard ? selection.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    // Prefer the Heard selection (a word or phrase); otherwise offer a one-word result, never a multi-word one.
    public static func dictionary(selection: String, selectionIsHeard: Bool, result: String) -> String {
        let selected = replacement(selection: selection, selectionIsHeard: selectionIsHeard)
        if !selected.isEmpty { return selected }
        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedResult.contains(where: \.isWhitespace) ? "" : trimmedResult
    }

    public enum Hint: Equatable {
        case selectFirst
        case usingHeard(String)
        case selectHeard
    }

    public static func hint(selection: String, selectionIsHeard: Bool) -> Hint {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .selectFirst }
        return selectionIsHeard ? .usingHeard(trimmed) : .selectHeard
    }
}
