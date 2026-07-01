import Foundation

// Post-STT text stage, runs before replacements (design.md §4.2.1). Handles spoken editing
// commands: insert a newline / paragraph break / tab, and "scratch that" (deletes the current
// segment — the words since the last sentence terminator or newline command). Sentence/newline
// aware. "scratch that" only fires when it sits at a clause boundary — its phrase ends with a
// terminator (. ! ?) or comma, or it ends the utterance — so literal usage like "scratch that
// lottery ticket" (a continuing word follows) is left as text. This relies on the STT punctuating
// a spoken correction; engines that do not (e.g. Apple) will under-fire rather than corrupt. The
// other (additive) commands fire inline regardless of boundary. The trigger phrases are
// configurable per command (LiveEditsStage.Commands) with sensible defaults; phrases match
// longest-first, so a multi-word command can never be shadowed by a shorter one. The additive
// commands all use an explicit "insert …" carrier phrase (with an optional "a") so a bare
// "new line" or "tab" spoken as prose is left as text. Matching tolerates a trailing terminator/comma
// on the phrase, and an additive command absorbs a pause comma the STT hung on the neighbouring word
// ("blah, insert new line, foo" → "blah\nfoo") — commas only, so a preceding sentence period survives.
// Verbatim tokenization happens later in the rewrite path (design.md §4.2).
public struct LiveEditsStage: PipelineStage {
    public let position = StagePosition.postSTTText
    public let order = StageOrder.liveEdits

    public struct Commands: Equatable, Sendable {
        public var newLine: [String]
        public var newParagraph: [String]
        public var scratchThat: [String]
        public var tab: [String]
        public init(
            newLine: [String] = ["insert new line", "insert a new line"],
            newParagraph: [String] = ["insert new paragraph", "insert a new paragraph"],
            scratchThat: [String] = ["scratch that"],
            tab: [String] = ["insert tab character", "insert a tab character"]
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

    public func apply(_ context: inout PipelineContext) {
        let tokens = context.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let lowered = tokens.map { $0.lowercased() }
        var parts: [String] = []
        var segmentStart = 0
        var i = 0
        // An additive command absorbs a comma the STT hung on the preceding word when the speaker
        // paused ("blah, insert new line" → "blah\n…") and on the following word (`absorbLeading`),
        // mirroring spliceAbsorbing for the token-based stage. Commas only — a preceding "." is a real
        // sentence end and is preserved ("done. insert new paragraph next" → "done.\n\nnext").
        var absorbLeading = false

        func resetSegment() { segmentStart = parts.count }

        while i < tokens.count {
            if let (action, length) = match(lowered, at: i) {
                let fires: Bool
                if action == .scratch {
                    let atUtteranceEnd = i + length >= tokens.count
                    fires = atUtteranceEnd || Self.hasBoundaryPunct(tokens[i + length - 1])
                } else {
                    fires = true
                }
                if fires {
                    let control: String?
                    switch action {
                    case .newline: control = Self.newline
                    case .paragraph: control = Self.paragraph
                    case .tab: control = Self.tab
                    case .scratch: control = nil
                    }
                    if let control {
                        if !parts.isEmpty { parts[parts.count - 1] = Self.stripTrailingComma(parts[parts.count - 1]) }
                        parts.append(control)
                        if action != .tab { resetSegment() }
                        absorbLeading = true
                    } else {
                        if segmentStart < parts.count { parts.removeSubrange(segmentStart..<parts.count) }
                        absorbLeading = false
                    }
                    i += length
                    continue
                }
            }

            var token = tokens[i]
            if absorbLeading {
                token = Self.stripLeadingComma(token)
                if !token.isEmpty { absorbLeading = false }
            }
            parts.append(token)
            if let last = token.last, last == "." || last == "!" || last == "?" {
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
            let matches = (0..<length).allSatisfy { k in
                let candidate = k == length - 1 ? Self.stripBoundaryPunct(lowered[i + k]) : lowered[i + k]
                return candidate == phrase.words[k]
            }
            if matches { return (phrase.action, length) }
        }
        return nil
    }

    // A trailing separator on the command's OWN last word is tolerated for matching and consumed with
    // the command (it is part of the operator, never emitted), so "insert new line," / ";" / "." all
    // fire. Broader than the comma-only NEIGHBOR absorption below, because here the punctuation sits on
    // the command itself, not on dictated content.
    private static func isBoundaryPunct(_ c: Character) -> Bool {
        c == "." || c == "!" || c == "?" || c == "," || c == ";" || c == ":"
    }

    private static func hasBoundaryPunct(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return isBoundaryPunct(last)
    }

    private static func stripBoundaryPunct(_ word: String) -> String {
        var word = word
        while let last = word.last, isBoundaryPunct(last) { word.removeLast() }
        return word
    }

    private static func stripTrailingComma(_ word: String) -> String {
        var word = word
        while word.last == "," { word.removeLast() }
        return word
    }

    private static func stripLeadingComma(_ word: String) -> String {
        var word = word
        while word.first == "," { word.removeFirst() }
        return word
    }

    private func join(_ parts: [String]) -> String {
        var out = ""
        out.reserveCapacity(parts.reduce(0) { $0 + $1.count + 1 })
        var endsWithBreak = true
        for part in parts {
            if part.isEmpty { continue }
            let isControl = part == Self.newline || part == Self.paragraph || part == Self.tab
            if !isControl && !endsWithBreak { out += " " }
            out += part
            if let last = part.last { endsWithBreak = last == "\n" || last == "\t" }
        }
        return out
    }
}
