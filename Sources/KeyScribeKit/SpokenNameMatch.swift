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

    public func matches(_ spoken: String, _ name: String) -> Bool {
        let spoken = VoiceCommandText.key(spoken)
        let name = VoiceCommandText.key(name)
        guard !spoken.isEmpty, !name.isEmpty else { return false }
        switch self {
        case .exact:
            return spoken == name || VoiceCommandText.compact(spoken) == VoiceCommandText.compact(name)
        case .partial:
            guard spoken != name, VoiceCommandText.compact(spoken).count >= 3 else { return false }
            let words = name.split(separator: " ")
            let wanted = spoken.split(separator: " ")
            guard wanted.count < words.count else { return false }
            return (0...(words.count - wanted.count)).contains { Array(words[$0..<$0 + wanted.count]) == wanted }
        case .words:
            guard VoiceCommandText.compact(spoken).count >= 3 else { return false }
            let words = Set(name.split(separator: " "))
            return spoken.split(separator: " ").allSatisfy(words.contains)
        }
    }

    public static func leading(
        _ words: [String], names: [String], limit: Int = .max, minimumWords: (SpokenNameMatch) -> Int = { _ in 1 }
    ) -> Leading? {
        let longest = names.map { VoiceCommandText.compact($0).count }.max() ?? 0
        let reach = min(words.count, limit, longest)
        guard reach > 0 else { return nil }
        for length in stride(from: reach, through: 1, by: -1) {
            let spoken = words.prefix(length).joined(separator: " ")
            for match in allCases where length >= minimumWords(match) {
                let hits = names.filter { match.matches(spoken, $0) && (match != .words || usesEachWordOnce(spoken, $0)) }
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
