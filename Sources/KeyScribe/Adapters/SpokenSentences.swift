import Foundation
import NaturalLanguage

enum SpokenSentences {
    static let shortest = 12

    static func split(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let pieces = tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var sentences: [String] = []
        var carried = ""
        for piece in pieces {
            let joined = carried.isEmpty ? piece : carried + " " + piece
            if joined.count < shortest {
                carried = joined
            } else {
                sentences.append(joined)
                carried = ""
            }
        }
        if !carried.isEmpty {
            if sentences.isEmpty { sentences.append(carried) } else { sentences[sentences.count - 1] += " " + carried }
        }
        return sentences
    }
}
