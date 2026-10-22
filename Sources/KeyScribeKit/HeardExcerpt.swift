public struct HeardExcerpt: Equatable, Sendable {
    public static let characterBudget = 80

    public let text: String

    public init?(heard: String) {
        let folded = heard.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !folded.isEmpty else { return nil }
        guard folded.count > Self.characterBudget else {
            text = "Heard \u{201C}\(folded)\u{201D}"
            return
        }
        var kept = Substring(folded.prefix(Self.characterBudget))
        while let last = kept.last, last.isWhitespace || last.isPunctuation { kept.removeLast() }
        text = "Heard \u{201C}\(kept)\u{2026}"
    }
}
