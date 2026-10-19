import Foundation

public enum VoiceCommandIntent: Equatable, Sendable {
    case focus(target: String)
    case runScript(target: String)
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

public enum VoiceCommandPhrase: CaseIterable, Sendable {
    case focus, run, goBack

    public var words: [String] {
        switch self {
        case .focus: ["switch to", "open"]
        case .run: [VoiceCommandGrammar.run]
        case .goBack: [VoiceCommandGrammar.goBack]
        }
    }

    var reaches: String? {
        switch self {
        case .focus: "an app or place"
        case .run: "a script or shortcut"
        case .goBack: nil
        }
    }

    public static var guidance: String {
        let clauses = allCases.map { phrase in
            let quoted = phrase.words.map { "\u{201C}\($0)\u{201D}" }.joined(separator: " or ")
            return phrase.reaches.map { "\(quoted) \($0)" } ?? quoted
        }
        return "say " + clauses.dropLast().joined(separator: ", ") + ", or " + (clauses.last ?? "")
    }
}

public enum VoiceCommandGrammar {
    static let focusVerbs = [
        "switch to", "switch two", "switch too",
        "which to", "which two", "which too",
        "witch to", "witch two", "witch too",
        "go to", "go two", "go too",
        "focus on", "focus", "open", "launch",
    ]
    static let goBack = "go back"
    static let run = "run"

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

    struct SpokenWord: Equatable {
        let key: String
        let end: String.Index
    }

    static func spokenWords(_ transcript: String) -> [SpokenWord] {
        var words: [SpokenWord] = []
        let scalars = transcript.unicodeScalars
        var start: String.Index?
        var index = scalars.startIndex
        func close(at end: String.Index) {
            guard let begin = start else { return }
            for key in VoiceCommandText.key(String(transcript[begin..<end])).split(separator: " ") {
                words.append(SpokenWord(key: String(key), end: end))
            }
            start = nil
        }
        while index < scalars.endIndex {
            if CharacterSet.alphanumerics.contains(scalars[index]) {
                if start == nil { start = index }
            } else {
                close(at: index)
            }
            index = scalars.index(after: index)
        }
        close(at: scalars.endIndex)
        return words
    }

    private static let textEdges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:.!?\u{2026}"))

    static func cleanedText(_ text: Substring) -> String {
        text.trimmingCharacters(in: textEdges)
    }

    public static func parse(_ transcript: String) -> VoiceCommandIntent? {
        let words = VoiceCommandText.key(transcript)
        if words == goBack { return .goBack }
        if words.hasPrefix(run + " ") {
            return .runScript(target: String(words.dropFirst(run.count + 1)))
        }
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
