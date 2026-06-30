import Foundation

public struct TextComparison: Equatable, Sendable {
    public struct Span: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Hashable, Sendable {
            case unchanged
            case formatting
            case removed
            case added
            case changed
        }

        public let id: Int
        public let text: String
        public let kind: Kind

        public init(id: Int, text: String, kind: Kind) {
            self.id = id
            self.text = text
            self.kind = kind
        }
    }

    public let left: [Span]
    public let right: [Span]
    public let hasMeaningfulDifference: Bool

    // A human-facing characterization of the diff, used for the status line. `substitution` is the
    // common dictation case (one misheard word swapped); `counts` covers everything larger;
    // `tooLongToCompare` is the long-entry fallback that knows the texts differ but not where.
    public enum Summary: Equatable, Sendable {
        case identical
        case formattingOnly
        case substitution(from: String, to: String)
        case counts(removed: Int, added: Int, changed: Int)
        case tooLongToCompare
    }

    public var summary: Summary {
        if !hasMeaningfulDifference {
            let anyFormatting = left.contains { $0.kind == .formatting }
                || right.contains { $0.kind == .formatting }
            return anyFormatting ? .formattingOnly : .identical
        }
        let removed = left.filter { $0.kind == .removed }
        let added = right.filter { $0.kind == .added }
        let changedLeft = left.filter { $0.kind == .changed }
        let changedRight = right.filter { $0.kind == .changed }
        // Differs, but the spans carry no per-token detail — only the long-entry `plain` fallback produces
        // this (the normal path always tags at least one removed/added/changed when meaningful).
        if removed.isEmpty, added.isEmpty, changedLeft.isEmpty, changedRight.isEmpty {
            return .tooLongToCompare
        }
        if removed.isEmpty, added.isEmpty, changedLeft.count == 1, changedRight.count == 1 {
            return .substitution(
                from: changedLeft[0].text.trimmingCharacters(in: .whitespacesAndNewlines),
                to: changedRight[0].text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .counts(removed: removed.count, added: added.count, changed: changedLeft.count)
    }

    // The LCS table is O(n·m) in token count, so a very long history entry (a dictated paragraph) would
    // spike memory and stall the viewer. Above this ceiling we skip the word-level diff and render each
    // side as plain text, still reporting whether the two differ.
    static let maxTokensForDiff = 2000

    public static func compare(_ left: String, _ right: String) -> TextComparison {
        let leftTokens = tokenize(left)
        let rightTokens = tokenize(right)
        if leftTokens.count > maxTokensForDiff || rightTokens.count > maxTokensForDiff {
            return plain(left: left, right: right)
        }
        let matches = lcs(leftTokens.map(\.normalized), rightTokens.map(\.normalized))
        var leftSpans: [Span] = []
        var rightSpans: [Span] = []
        var leftIndex = 0
        var rightIndex = 0

        for match in matches {
            appendGap(
                leftTokens: Array(leftTokens[leftIndex..<match.left]),
                rightTokens: Array(rightTokens[rightIndex..<match.right]),
                leftSpans: &leftSpans,
                rightSpans: &rightSpans)

            let l = leftTokens[match.left]
            let r = rightTokens[match.right]
            let kind: Span.Kind = l.text == r.text ? .unchanged : .formatting
            appendToken(l, kind: kind, to: &leftSpans)
            appendToken(r, kind: kind, to: &rightSpans)
            leftIndex = match.left + 1
            rightIndex = match.right + 1
        }

        appendGap(
            leftTokens: Array(leftTokens[leftIndex...]),
            rightTokens: Array(rightTokens[rightIndex...]),
            leftSpans: &leftSpans,
            rightSpans: &rightSpans)

        return TextComparison(
            left: merge(leftSpans),
            right: merge(rightSpans),
            hasMeaningfulDifference: leftSpans.contains { $0.kind == .removed || $0.kind == .changed }
                || rightSpans.contains { $0.kind == .added || $0.kind == .changed })
    }

    private static func plain(left: String, right: String) -> TextComparison {
        TextComparison(
            left: left.isEmpty ? [] : [Span(id: 0, text: left, kind: .unchanged)],
            right: right.isEmpty ? [] : [Span(id: 0, text: right, kind: .unchanged)],
            hasMeaningfulDifference: left != right)
    }

    private struct Token: Equatable {
        let text: String
        let normalized: String
    }

    private struct Match {
        let left: Int
        let right: Int
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""

        func flushCurrent() {
            guard !current.isEmpty else { return }
            tokens.append(Token(text: current, normalized: normalize(current)))
            current = ""
        }

        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
                current.unicodeScalars.append(scalar)
            } else {
                flushCurrent()
                tokens.append(Token(text: String(scalar), normalized: ""))
            }
        }
        flushCurrent()
        return tokens
    }

    private static func normalize(_ text: String) -> String {
        text.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" }
            .map { String($0).lowercased() }
            .joined()
    }

    private static func lcs(_ left: [String], _ right: [String]) -> [Match] {
        let leftCount = left.count
        let rightCount = right.count
        guard leftCount > 0, rightCount > 0 else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: rightCount + 1), count: leftCount + 1)

        for i in stride(from: leftCount - 1, through: 0, by: -1) {
            for j in stride(from: rightCount - 1, through: 0, by: -1) {
                if !left[i].isEmpty, left[i] == right[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var matches: [Match] = []
        var i = 0
        var j = 0
        while i < leftCount, j < rightCount {
            if !left[i].isEmpty, left[i] == right[j] {
                matches.append(Match(left: i, right: j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matches
    }

    private static func appendGap(
        leftTokens: [Token],
        rightTokens: [Token],
        leftSpans: inout [Span],
        rightSpans: inout [Span]
    ) {
        let leftWords = leftTokens.filter { !$0.normalized.isEmpty }
        let rightWords = rightTokens.filter { !$0.normalized.isEmpty }
        let leftKind: Span.Kind
        let rightKind: Span.Kind

        if leftWords.isEmpty, rightWords.isEmpty {
            let kind: Span.Kind = leftTokens.map(\.text).joined() == rightTokens.map(\.text).joined()
                ? .unchanged
                : .formatting
            for token in leftTokens { appendToken(token, kind: kind, to: &leftSpans) }
            for token in rightTokens { appendToken(token, kind: kind, to: &rightSpans) }
            return
        } else if !leftWords.isEmpty, !rightWords.isEmpty {
            leftKind = .changed
            rightKind = .changed
        } else {
            leftKind = .removed
            rightKind = .added
        }

        for token in leftTokens {
            appendToken(token, kind: token.normalized.isEmpty ? .formatting : leftKind, to: &leftSpans)
        }
        for token in rightTokens {
            appendToken(token, kind: token.normalized.isEmpty ? .formatting : rightKind, to: &rightSpans)
        }
    }

    private static func appendToken(_ token: Token, kind: Span.Kind, to spans: inout [Span]) {
        spans.append(Span(id: spans.count, text: token.text, kind: kind))
    }

    private static func merge(_ spans: [Span]) -> [Span] {
        var merged: [Span] = []
        for span in spans {
            if let last = merged.last, last.kind == span.kind {
                merged[merged.count - 1] = Span(id: last.id, text: last.text + span.text, kind: last.kind)
            } else {
                merged.append(Span(id: merged.count, text: span.text, kind: span.kind))
            }
        }
        return merged
    }
}
