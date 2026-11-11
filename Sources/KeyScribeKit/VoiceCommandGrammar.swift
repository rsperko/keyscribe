import Foundation

public enum VoiceCommandReach: Equatable, Sendable {
    case running
    case opening
}

public enum VoiceCommandIntent: Equatable, Sendable {
    case focus(target: String, reach: VoiceCommandReach)
    case runScript(target: String)
    case goBack
    case repeatSummary
    case cancel
    case help
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
    case open, switchTo, run, goBack

    public var words: [String] {
        switch self {
        case .open: ["open"]
        case .switchTo: ["switch to"]
        case .run: [VoiceCommandGrammar.run]
        case .goBack: [VoiceCommandGrammar.goBack]
        }
    }

    var reaches: String? {
        switch self {
        case .open: "an app or place"
        case .switchTo: "one that\u{2019}s already open"
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
    static let runningVerbs = [
        "switch to", "switch two", "switch too",
        "which to", "which two", "which too",
        "witch to", "witch two", "witch too",
        "go to", "go two", "go too",
        "focus on", "focus",
    ]
    static let openingVerbs = ["open", "launch"]
    static let focusVerbs = runningVerbs + openingVerbs
    public static let goBack = "go back"
    public static let repeatSummary = ["repeat that", "say that again"]
    static let run = "run"
    public static let cancel = ["cancel", "never mind", "nevermind"]
    public static let help = ["what can I say", "show commands"]
    static let polite = "please"
    private static let politeVerbs: Set<String> = ["open", "launch", "switch to", "go to", "focus on", "focus"]

    private static let focusVerbPrefix: NSRegularExpression = {
        let gap = "[^\\p{L}\\p{N}]+"
        let verbs = focusVerbs.map { $0.split(separator: " ").joined(separator: gap) }.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "^[^\\p{L}\\p{N}]*(?:\(polite)\(gap))*(?:\(verbs))(?![\\p{L}\\p{N}])[^\\p{L}\\p{N}]*", options: [.caseInsensitive])
    }()

    static func politeStart(_ transcript: String) -> Int {
        spokenWords(transcript).prefix { $0.key == polite }.count
    }

    static func targetStart(_ transcript: String) -> Int? {
        let keys = spokenWords(transcript).map(\.key)
        let lead = keys.prefix { $0 == polite }.count
        let said = Array(keys.dropFirst(lead))
        if said.first == run { return lead + 1 }
        guard let verb = focusVerbs.map({ $0.split(separator: " ").map(String.init) }).first(where: { said.starts(with: $0) })
        else { return nil }
        let start = lead + verb.count
        return start + 1 < keys.count && keys[start] == "the" ? start + 1 : start
    }

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
        var said = VoiceCommandText.key(transcript).split(separator: " ").map(String.init)
        let leading = said.prefix { $0 == polite }.count
        said.removeFirst(leading)
        let trailing = said.count > 1 && said.last == polite
        if trailing { said.removeLast() }
        let words = said.joined(separator: " ")
        if words == goBack { return .goBack }
        if repeatSummary.contains(words) { return .repeatSummary }
        if cancel.contains(words) { return .cancel }
        if help.contains(where: { $0.lowercased() == words }) { return .help }
        if words.hasPrefix(run + " ") {
            return .runScript(target: String(words.dropFirst(run.count + 1)))
        }
        for verb in focusVerbs {
            guard words.hasPrefix(verb + " ") else { continue }
            guard leading + (trailing ? 1 : 0) == 0 || politeVerbs.contains(verb) else { return nil }
            var target = String(words.dropFirst(verb.count + 1))
            if target.hasPrefix("the ") { target.removeFirst(4) }
            guard !target.isEmpty, target != "the" else { return nil }
            return .focus(target: target, reach: openingVerbs.contains(verb) ? .opening : .running)
        }
        return nil
    }
}
