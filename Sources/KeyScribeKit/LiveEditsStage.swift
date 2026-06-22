import Foundation

// Post-STT text stage, runs before replacements (design.md §4.2.1). Handles spoken editing
// commands: insert a newline / paragraph break / tab, and "scratch that" (deletes the current
// segment — the words since the last sentence terminator or newline command). Sentence/newline
// aware. The trigger phrases are configurable per command (LiveEditsStage.Commands) with sensible
// defaults; phrases match longest-first, so a multi-word command can never be shadowed by a shorter
// one. Bare single words like "tab" or "paragraph" are intentionally NOT defaults (too easily
// spoken literally). Verbatim tokenization happens later in the rewrite path (design.md §4.2).
public struct LiveEditsStage: PipelineStage {
    public let position = StagePosition.postSTTText
    public let order = StageOrder.liveEdits

    public struct Commands: Equatable, Sendable {
        public var newLine: [String]
        public var newParagraph: [String]
        public var scratchThat: [String]
        public var tab: [String]
        public init(
            newLine: [String] = ["new line"],
            newParagraph: [String] = ["new paragraph"],
            scratchThat: [String] = ["scratch that"],
            tab: [String] = ["tab key", "insert tab"]
        ) {
            self.newLine = newLine
            self.newParagraph = newParagraph
            self.scratchThat = scratchThat
            self.tab = tab
        }
        public static let `default` = Commands()
    }

    private enum Action { case newline, paragraph, tab, scratch }
    private let phrases: [(words: [String], action: Action)]

    public init(commands: Commands = .default) {
        var list: [(words: [String], action: Action)] = []
        func add(_ raw: [String], _ action: Action) {
            for phrase in raw {
                let words = phrase.lowercased().split(separator: " ").map(String.init)
                if !words.isEmpty { list.append((words, action)) }
            }
        }
        add(commands.newLine, .newline)
        add(commands.newParagraph, .paragraph)
        add(commands.scratchThat, .scratch)
        add(commands.tab, .tab)
        phrases = list.sorted { $0.words.count > $1.words.count }
    }

    private static let newline = "\u{0A}"
    private static let paragraph = "\u{0A}\u{0A}"
    private static let tab = "\u{09}"

    public func run(_ context: inout PipelineContext) {
        let tokens = context.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let lowered = tokens.map { $0.lowercased() }
        var parts: [String] = []
        var segmentStart = 0
        var i = 0

        func resetSegment() { segmentStart = parts.count }

        while i < tokens.count {
            if let (action, length) = match(lowered, at: i) {
                switch action {
                case .newline: parts.append(Self.newline); resetSegment()
                case .paragraph: parts.append(Self.paragraph); resetSegment()
                case .tab: parts.append(Self.tab)
                case .scratch: if segmentStart < parts.count { parts.removeSubrange(segmentStart..<parts.count) }
                }
                i += length
                continue
            }

            parts.append(tokens[i])
            if let last = tokens[i].last, last == "." || last == "!" || last == "?" {
                resetSegment()
            }
            i += 1
        }

        context.text = join(parts)
    }

    private func match(_ lowered: [String], at i: Int) -> (Action, Int)? {
        for phrase in phrases {
            let length = phrase.words.count
            guard i + length <= lowered.count else { continue }
            if (0..<length).allSatisfy({ lowered[i + $0] == phrase.words[$0] }) {
                return (phrase.action, length)
            }
        }
        return nil
    }

    private func join(_ parts: [String]) -> String {
        var out = ""
        for part in parts {
            if part == Self.newline || part == Self.paragraph || part == Self.tab {
                out += part
            } else {
                if !out.isEmpty && !out.hasSuffix("\n") && !out.hasSuffix("\t") { out += " " }
                out += part
            }
        }
        return out
    }
}
