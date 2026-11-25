import Foundation

public struct SpokenEvalCase: Decodable, Equatable, Sendable {
    public let id: String
    public let asked: String?
    public let reply: String
    public let mentions: [String]
    public let avoids: [String]

    public init(id: String, asked: String?, reply: String, mentions: [String], avoids: [String]) {
        self.id = id
        self.asked = asked
        self.reply = reply
        self.mentions = mentions
        self.avoids = avoids
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id), asked: try c.decodeIfPresent(String.self, forKey: .asked),
            reply: try c.decode(String.self, forKey: .reply), mentions: try c.decode([String].self, forKey: .mentions),
            avoids: try c.decodeIfPresent([String].self, forKey: .avoids) ?? [])
    }

    private enum CodingKeys: String, CodingKey { case id, asked, reply, mentions, avoids }
}

public enum SpokenEval {
    private struct File: Decodable { let cases: [SpokenEvalCase] }

    public struct BadPattern: Error, Equatable {
        public let pattern: String
    }

    public static func cases(from data: Data) throws -> [SpokenEvalCase] {
        let cases = try JSONDecoder().decode(File.self, from: data).cases
        for pattern in cases.flatMap({ $0.mentions + $0.avoids }) where (try? NSRegularExpression(pattern: pattern)) == nil {
            throw BadPattern(pattern: pattern)
        }
        return cases
    }

    public static func failures(of summary: String, for evalCase: SpokenEvalCase) -> [String] {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ["empty"] }
        var failures: [String] = []
        if !evalCase.mentions.allSatisfy({ matches($0, summary) }) { failures.append("missed") }
        if evalCase.avoids.contains(where: { matches($0, summary) }) { failures.append("said") }
        if matches(#"#\d|\d{5,}"#, summary) { failures.append("number") }
        return failures
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        RegexCache.regex(pattern, options: [.caseInsensitive])?
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
