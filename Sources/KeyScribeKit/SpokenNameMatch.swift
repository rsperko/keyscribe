import Foundation

public enum SpokenNameMatch: CaseIterable, Sendable {
    case exact, partial, words

    public struct Leading: Equatable, Sendable {
        public let length: Int
        public let names: [String]

        public init(length: Int, names: [String]) {
            self.length = length
            self.names = names
        }
    }

    struct Keyed: Sendable {
        let key: String
        let compact: String

        init(_ text: String, fold: (String) -> String) {
            key = VoiceCommandText.key(text).split(separator: " ").map { fold(String($0)) }.joined(separator: " ")
            compact = String(decoding: key.utf8.filter { $0 != UInt8(ascii: " ") }, as: UTF8.self)
        }
    }

    public func matches(_ spoken: String, _ name: String, fold: (String) -> String = { $0 }) -> Bool {
        matches(Keyed(spoken, fold: fold), Keyed(name, fold: fold))
    }

    func matches(_ spoken: Keyed, _ name: Keyed) -> Bool {
        guard !spoken.key.isEmpty, !name.key.isEmpty else { return false }
        switch self {
        case .exact:
            return spoken.key == name.key || spoken.compact == name.compact
        case .partial:
            guard spoken.key != name.key, spoken.compact.count >= 3 else { return false }
            let words = name.key.split(separator: " ")
            let wanted = spoken.key.split(separator: " ")
            guard wanted.count < words.count else { return false }
            return (0...(words.count - wanted.count)).contains { Array(words[$0..<$0 + wanted.count]) == wanted }
        case .words:
            guard spoken.compact.count >= 3 else { return false }
            let words = Set(name.key.split(separator: " "))
            return spoken.key.split(separator: " ").allSatisfy(words.contains)
        }
    }

    public static func leading(
        _ words: [String], names: [String], limit: Int = .max, fold: (String) -> String = { $0 },
        minimumWords: (SpokenNameMatch) -> Int = { _ in 1 }
    ) -> Leading? {
        leading(
            words, keyed: names.map { ($0, Keyed($0, fold: fold)) }, longest: names.map { VoiceCommandText.compact($0).count }.max() ?? 0,
            limit: limit, fold: fold, minimumWords: minimumWords)
    }

    static func leading(
        _ words: [String], keyed: [(String, Keyed)], longest: Int, limit: Int, fold: (String) -> String,
        minimumWords: (SpokenNameMatch) -> Int
    ) -> Leading? {
        let reach = min(words.count, limit, longest)
        guard reach > 0 else { return nil }
        for length in stride(from: reach, through: 1, by: -1) {
            let spoken = Keyed(words.prefix(length).joined(separator: " "), fold: fold)
            for match in allCases where length >= minimumWords(match) {
                let hits = keyed.filter { match.matches(spoken, $0.1) && (match != .words || usesEachWordOnce(spoken.key, $0.1.key)) }.map(\.0)
                if !hits.isEmpty { return Leading(length: length, names: hits) }
            }
        }
        return nil
    }

    private static func usesEachWordOnce(_ spoken: String, _ name: String) -> Bool {
        var left = VoiceCommandText.key(name).split(separator: " ")
        for word in VoiceCommandText.key(spoken).split(separator: " ") {
            guard let index = left.firstIndex(of: word) else { return false }
            left.remove(at: index)
        }
        return true
    }
}
