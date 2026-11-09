import Foundation

public enum AgentRename: Equatable, Sendable {
    case rename(String)
    case invalid(Problem)

    public enum Problem: Error, Equatable, Sendable {
        case noName
        case tooLong
        case moreAfterName
    }

    public static let nameWords = 4

    private static let currentObjects = [["this", "session"], ["this", "conversation"]]
    private static let renameLinks: Set<String> = ["to", "too"]
    private static let clauseEnds: Set<Character> = [".", "!", "?", ";", ":", ","]

    public static func parse(_ transcript: String) -> AgentRename? {
        switch request(in: transcript) {
        case nil: nil
        case .failure(let problem): .invalid(problem)
        case .success(let spoken): name(from: spoken)
        }
    }

    public static func request(in transcript: String) -> Result<Substring, Problem>? {
        let words = VoiceCommandGrammar.spokenWords(transcript)
        let keys = words.map(\.key)
        guard let verb = keys.first, ["rename", "name", "call"].contains(verb),
              let object = currentObjects.first(where: { Array(keys.dropFirst().prefix($0.count)) == $0 })
        else { return nil }
        var commandEnd = object.count
        if verb == "rename" {
            guard commandEnd + 1 < keys.count, renameLinks.contains(keys[commandEnd + 1]) else { return .failure(.noName) }
            commandEnd += 1
        }
        return .success(transcript[words[commandEnd].end...])
    }

    public static func name<S: StringProtocol>(from spoken: S) -> AgentRename {
        let rest = Substring(spoken)
        let clause = rest[..<(clauseEnd(in: rest) ?? rest.endIndex)]
        if clause.endIndex < rest.endIndex, rest[clause.endIndex...].contains(where: { $0.isLetter || $0.isNumber }) {
            return .invalid(.moreAfterName)
        }
        let name = clause.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let count = AgentHandles.normalize(name).split(separator: " ").count
        if count == 0 { return .invalid(.noName) }
        if count > nameWords { return .invalid(.tooLong) }
        return .rename(name)
    }

    private static func clauseEnd(in text: Substring) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index].isNewline { return index }
            if clauseEnds.contains(text[index]), next == text.endIndex || text[next].isWhitespace { return index }
            index = next
        }
        return nil
    }
}
