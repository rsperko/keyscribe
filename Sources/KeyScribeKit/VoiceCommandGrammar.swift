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

    private static let focusVerbPrefix: NSRegularExpression = {
        let gap = "[^\\p{L}\\p{N}]+"
        let verbs = focusVerbs.map { $0.split(separator: " ").joined(separator: gap) }.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "^[^\\p{L}\\p{N}]*(?:\(verbs))(?![\\p{L}\\p{N}])[^\\p{L}\\p{N}]*", options: [.caseInsensitive])
    }()

    static func targetRange(in transcript: String) -> Range<String.Index>? {
        guard case .focus = parse(transcript),
              let match = focusVerbPrefix.firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)),
              let verb = Range(match.range, in: transcript)
        else { return nil }
        return verb.upperBound..<transcript.endIndex
    }

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
