import Foundation

// Post-STT text stage, runs before replacements (design.md §4.2.1). Handles spoken editing
// commands: insert a newline / paragraph break / tab, and "scratch that" (deletes what was just
// said). Every command — a newline/paragraph/tab control char AND a verbatim/clipboard nonce token
// that a prior tokenizer already spliced in — is a hard scratch boundary and its own undoable unit.
// "scratch that" removes the most recent unit and never reaches past a command: dictated words since
// the last boundary are removed; if nothing was said since the last boundary and it is a command,
// that command is cancelled (undo the newline / tab / clipboard insert); if it is prose (a punctuating
// STT like Whisper ended the clause with its own terminator), scratch falls back to removing the one
// previous clause — back to the nearest terminator/comma/semicolon/colon or command boundary.
// Removing a clause rather than a whole sentence bounds the damage of a
// mis-fire: under-deleting is re-issuable, over-deleting is silent. "scratch that" only fires when it
// sits at a clause boundary — its phrase ends with a terminator (. ! ?) or comma, or it ends the
// utterance — so literal usage like "scratch that lottery ticket" (a continuing word follows) is
// left as text. This relies on the STT punctuating a spoken correction; engines that do not (e.g.
// Apple) will under-fire rather than corrupt. The
// other (additive) commands fire inline regardless of boundary. The trigger phrases are
// configurable per command (LiveEditsStage.Commands) with sensible defaults; phrases match
// longest-first, so a multi-word command can never be shadowed by a shorter one. The additive
// commands all use an explicit "insert …" carrier phrase (with an optional "a") so a bare
// "new line" or "tab" spoken as prose is left as text. Matching tolerates a trailing terminator/comma
// on the phrase's last word, a pause comma INSIDE the phrase — whether hung on a word ("insert, new
// line") or as a standalone token ("insert , new line") — and a pause comma the STT hung on the
// neighbouring word ("blah, insert new line, foo" → "blah\nfoo"). Commas only in every case, so a
// preceding OR interior sentence period survives ("insert new. Paragraph two" is not eaten by the
// command). Verbatim tokenization happens later in the rewrite path (design.md §4.2).
public struct LiveEditsStage: PipelineStage {
    public let position = StagePosition.postSTTText
    public let order = StageOrder.liveEdits

    public struct Commands: Equatable, Sendable {
        public var newLine: [String]
        public var newParagraph: [String]
        public var scratchThat: [String]
        public var tab: [String]
        public init(
            newLine: [String] = ["insert new line", "insert a new line", "insert a newline", "insert newline"],
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
            if let (action, consumed) = match(lowered, at: i) {
                let fires: Bool
                if action == .scratch {
                    let atUtteranceEnd = i + consumed >= tokens.count
                    fires = atUtteranceEnd || Self.hasBoundaryPunct(tokens[i + consumed - 1])
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
                        resetSegment()
                        absorbLeading = true
                    } else {
                        if segmentStart < parts.count {
                            parts.removeSubrange(segmentStart..<parts.count)
                        } else if segmentStart > 0 {
                            let prevIndex = segmentStart - 1
                            if Self.isCommandPart(parts[prevIndex]) {
                                parts.remove(at: prevIndex)
                            } else {
                                var prevStart = prevIndex
                                while prevStart > 0 {
                                    let before = parts[prevStart - 1]
                                    if Self.isCommandPart(before) { break }
                                    if Self.hasBoundaryPunct(before) { break }
                                    prevStart -= 1
                                }
                                parts.removeSubrange(prevStart..<segmentStart)
                            }
                            resetSegment()
                        }
                        absorbLeading = false
                    }
                    i += consumed
                    continue
                }
            }

            var token = tokens[i]
            if absorbLeading {
                token = Self.stripLeadingComma(token)
                if !token.isEmpty { absorbLeading = false }
            }
            parts.append(token)
            if Self.endsWithSentenceTerminator(token) || SentinelText.containsSentinel(token) {
                resetSegment()
            }
            i += 1
        }

        context.text = join(parts)
    }

    // Returns the matched action and the number of transcript tokens it consumes — which can exceed the
    // phrase's word count, because a pause between the operator's own words can surface as either a
    // comma hung on a word ("insert, new line") OR a standalone comma token ("insert , new line"). Both
    // are prosody artifacts of the same pause and are absorbed into the command, mirroring the
    // commas-only absorption already applied to a command's neighbours. Interior periods are left to
    // block a match on purpose, so a real sentence boundary ("insert new. Paragraph two…") survives
    // rather than being eaten by the command.
    private func match(_ lowered: [String], at start: Int) -> (Action, Int)? {
        for phrase in phrases {
            var j = start
            var matched = true
            for (k, word) in phrase.words.enumerated() {
                if k > 0 {
                    while j < lowered.count, Self.isStandaloneComma(lowered[j]) { j += 1 }
                }
                guard j < lowered.count else { matched = false; break }
                // The command's LAST word tolerates a trailing terminator/comma/`;`/`:` (the boundary
                // punct that sits AFTER the whole operator); an INTERIOR word tolerates only a trailing
                // comma (a pause artifact).
                let candidate = k == phrase.words.count - 1 ? Self.stripBoundaryPunct(lowered[j]) : Self.stripTrailingComma(lowered[j])
                if candidate != word { matched = false; break }
                j += 1
            }
            if matched { return (phrase.action, j - start) }
        }
        return nil
    }

    // A token that is nothing but commas — the STT's rendering of a bare pause between words.
    private static func isStandaloneComma(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0 == "," }
    }

    // A trailing separator on the command's OWN last word is tolerated for matching and consumed with
    // the command (it is part of the operator, never emitted), so "insert new line," / ";" / "." all
    // fire. Broader than the comma-only NEIGHBOR absorption below, because here the punctuation sits on
    // the command itself, not on dictated content.
    private static func isBoundaryPunct(_ c: Character) -> Bool {
        c == "." || c == "!" || c == "?" || c == "," || c == ";" || c == ":"
    }

    private static func isCommandPart(_ part: String) -> Bool {
        part == newline || part == paragraph || part == tab || SentinelText.containsSentinel(part)
    }

    private static func hasBoundaryPunct(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return isBoundaryPunct(last)
    }

    private static func endsWithSentenceTerminator(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return last == "." || last == "!" || last == "?"
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
