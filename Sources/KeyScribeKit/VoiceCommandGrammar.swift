import Foundation

public enum VoiceCommandIntent: Equatable, Sendable {
    case focus(target: String)
    case goBack
}

public enum VoiceCommandText {
    public static func key(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let spaced = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(spaced).split(separator: " ").joined(separator: " ")
    }

    public static func compact(_ text: String) -> String {
        key(text).replacingOccurrences(of: " ", with: "")
    }
}

public enum VoiceCommandGrammar {
    static let focusVerbs = ["switch to", "go to", "focus on", "focus", "open", "launch"]
    static let goBack = "go back"

    public static func parse(_ transcript: String) -> VoiceCommandIntent? {
        let words = VoiceCommandText.key(transcript)
        if words == goBack { return .goBack }
        for verb in focusVerbs {
            guard words.hasPrefix(verb + " ") else { continue }
            var target = String(words.dropFirst(verb.count + 1))
            if target.hasPrefix("the ") { target.removeFirst(4) }
            guard !target.isEmpty, target != "the" else { return nil }
            return .focus(target: target)
        }
        return nil
    }
}
