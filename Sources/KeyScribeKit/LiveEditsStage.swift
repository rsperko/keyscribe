import Foundation

// Post-STT text stage, runs before replacements (design.md §4.2.1). Handles the small documented
// spoken-command list: "new line", "new paragraph", and "scratch that" (deletes the current
// segment — the words since the last sentence terminator or newline command). Sentence/newline
// aware. Custom trigger words, an escape mechanism, and verbatim tokenization come later
// (verbatim is M6). Bare "paragraph" is intentionally not a command (too easily spoken literally).
public struct LiveEditsStage: PipelineStage {
    public let position = StagePosition.postSTTText
    public let order = StageOrder.liveEdits

    public init() {}

    private static let newline = "\u{0A}"
    private static let paragraph = "\u{0A}\u{0A}"

    public func run(_ context: inout PipelineContext) {
        let tokens = context.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var parts: [String] = []
        var segmentStart = 0
        var i = 0

        func resetSegment() { segmentStart = parts.count }

        while i < tokens.count {
            let word = tokens[i].lowercased()
            let next = i + 1 < tokens.count ? tokens[i + 1].lowercased() : ""

            if word == "new", next == "line" {
                parts.append(Self.newline); resetSegment(); i += 2; continue
            }
            if word == "new", next == "paragraph" {
                parts.append(Self.paragraph); resetSegment(); i += 2; continue
            }
            if word == "scratch", next == "that" {
                if segmentStart < parts.count { parts.removeSubrange(segmentStart..<parts.count) }
                i += 2; continue
            }

            parts.append(tokens[i])
            if let last = tokens[i].last, last == "." || last == "!" || last == "?" {
                resetSegment()
            }
            i += 1
        }

        context.text = join(parts)
    }

    private func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts {
            if part == Self.newline || part == Self.paragraph {
                out += part
            } else {
                if !out.isEmpty && !out.hasSuffix("\n") { out += " " }
                out += part
            }
        }
        return out
    }
}
