import Foundation

// Post-STT text stage, runs before replacements (design.md §4.2.1). Handles spoken editing commands:
// insert newline / paragraph / tab, "scratch that" (deletes what was just said), and "never mind" (discards
// the whole take, only when said on its own at the very end, so "we need to start over" stays text). Every command —
// a control char AND a verbatim/clipboard nonce token a prior tokenizer spliced in — is a hard scratch
// boundary and its own undoable unit.
//
// "scratch that" removes the most recent unit and never reaches past a command: it deletes dictated
// words since the last boundary, or, when the same sentence goes on after it (the command ends with a comma
// or no punctuation) with at least two of those words in a row, only from there ("…to the store to buy milk, scratch that, to the mall" → "…to the mall"); if nothing was said and the last unit is a command, it cancels that
// command; if it is prose (a punctuating STT ended the clause), it removes the one previous clause —
// back to the nearest terminator/comma/;/: or command boundary. Clause-not-sentence bounds a mis-fire
// (under-deleting is re-issuable, over-deleting is silent). It only fires at a clause boundary (its
// phrase ends with . ! ? or comma, or ends the utterance), so "scratch that lottery ticket" stays text.
// Relies on the STT punctuating; engines that don't (Apple) under-fire rather than corrupt.
//
// Additive commands fire inline regardless of boundary, use an explicit "insert …" carrier (optional
// "a") so a bare "new line" stays text, and match longest-first so a shorter phrase can't shadow a
// longer. Matching tolerates a trailing terminator/comma on the last word and a pause comma inside or
// on a neighbouring word ("blah, insert new line, foo" → "blah\nfoo") — commas only, so a sentence
// period survives ("insert new. Paragraph two"). Verbatim tokenization is later (design.md §4.2).
public enum SpokenEdit: String, Sendable, Equatable {
    case newLine = "new line"
    case newParagraph = "new paragraph"
    case tab
    case scratchThat = "scratch that"

    public static func summary(_ edits: [SpokenEdit]) -> String? {
        var order: [SpokenEdit] = []
        var counts: [SpokenEdit: Int] = [:]
        for edit in edits {
            if counts[edit] == nil { order.append(edit) }
            counts[edit, default: 0] += 1
        }
        guard !order.isEmpty else { return nil }
        return order.map { counts[$0]! > 1 ? "\($0.rawValue) \u{00D7}\(counts[$0]!)" : $0.rawValue }.joined(separator: ", ")
    }

    public static func historyFacts(_ summary: String?) -> [HistoryEntry.Fact]? {
        summary.map { [HistoryEntry.Fact(label: "Spoken edits", value: $0)] }
    }
}

public struct LiveEditsStage: PipelineStage {
    public let position = StagePosition.postSTTText
    public let order = StageOrder.liveEdits

    public struct Commands: Equatable, Sendable {
        public var newLine: [String]
        public var newParagraph: [String]
        public var scratchThat: [String]
        public var tab: [String]
        public var discard: [String]
        public init(
            newLine: [String] = ["insert new line", "insert a new line", "insert a newline", "insert newline"],
            newParagraph: [String] = ["insert new paragraph", "insert a new paragraph"],
            scratchThat: [String] = ["scratch that", "scratch dat", "scratchdat", "stratch that", "stratchdat"],
            tab: [String] = ["insert tab character", "insert a tab character"],
            discard: [String] = ["never mind", "nevermind", "start over"]
        ) {
            self.newLine = newLine
            self.newParagraph = newParagraph
            self.scratchThat = scratchThat
            self.tab = tab
            self.discard = discard
        }
        public static let `default` = Commands()
    }

    private enum Action { case newline, paragraph, tab, scratch, discard }
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
        add(commands.discard, .discard)
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
        // An additive command absorbs a comma the STT hung on the preceding word ("blah, insert new
        // line" → "blah\n…") and on the following word (`absorbLeading`). Commas only — a preceding "."
        // is a real sentence end and is preserved ("done. insert new paragraph next" → "done.\n\nnext").
        var absorbLeading = false

        func resetSegment() { segmentStart = parts.count }

        while i < tokens.count {
            if let (action, consumed) = firingCommand(tokens, lowered, at: i) {
                if action == .discard {
                    context.text = ""
                    context.discarded = true
                    return
                }
                let control: String?
                switch action {
                case .newline: control = Self.newline; context.spokenEdits.append(.newLine)
                case .paragraph: control = Self.paragraph; context.spokenEdits.append(.newParagraph)
                case .tab: control = Self.tab; context.spokenEdits.append(.tab)
                case .scratch, .discard: control = nil; context.spokenEdits.append(.scratchThat)
                }
                if let control {
                    if !parts.isEmpty { parts[parts.count - 1] = Self.stripTrailingComma(parts[parts.count - 1]) }
                    parts.append(control)
                    resetSegment()
                    absorbLeading = true
                } else {
                    if segmentStart < parts.count {
                        let restarts = Self.endsWithSentenceTerminator(tokens[i + consumed - 1])
                        let correction = restarts ? [] : correctionWords(tokens, lowered, from: i + consumed)
                        let cut = Self.repairStart(parts[segmentStart...], correction) ?? segmentStart
                        parts.removeSubrange(cut..<parts.count)
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

    // Returns the matched action and tokens consumed — which can exceed the phrase's word count, since a
    // pause between the operator's words surfaces as a hung comma ("insert, new line") or a standalone
    // comma token ("insert , new line"); both are absorbed. Interior periods block a match on purpose so
    // a real sentence boundary ("insert new. Paragraph two") survives.
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

    private func firingCommand(_ tokens: [String], _ lowered: [String], at i: Int) -> (Action, Int)? {
        guard let (action, consumed) = match(lowered, at: i) else { return nil }
        let atUtteranceEnd = i + consumed >= tokens.count
        switch action {
        case .discard:
            return atUtteranceEnd && (i == 0 || Self.hasBoundaryPunct(tokens[i - 1])) ? (action, consumed) : nil
        case .scratch:
            return atUtteranceEnd || Self.hasBoundaryPunct(tokens[i + consumed - 1]) ? (action, consumed) : nil
        case .newline, .paragraph, .tab:
            return (action, consumed)
        }
    }

    private func correctionWords(_ tokens: [String], _ lowered: [String], from start: Int) -> [String] {
        var words: [String] = []
        var j = start
        while j < tokens.count, firingCommand(tokens, lowered, at: j) == nil, !SentinelText.containsSentinel(tokens[j]) {
            words.append(Self.comparable(tokens[j]))
            if Self.endsWithSentenceTerminator(tokens[j]) { break }
            j += 1
        }
        return words.filter { !$0.isEmpty }
    }

    // Where the scratched words a correction replaces begin: only where the correction starts with at least
    // two of them in a row (the longest run, the earliest on a tie). Anything less is a restart, nil.
    private static func repairStart(_ scratched: ArraySlice<String>, _ correction: [String]) -> Int? {
        let words = scratched.map(comparable)
        var best: (start: Int, run: Int)?
        for start in words.indices {
            let run = zip(words[start...], correction).prefix { !$0.isEmpty && $0 == $1 }.count
            if run >= 2, run > (best?.run ?? 0) { best = (start, run) }
        }
        return best.map { scratched.startIndex + $0.start }
    }

    private static func comparable(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    // A token that is nothing but commas — the STT's rendering of a bare pause between words.
    private static func isStandaloneComma(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0 == "," }
    }

    // A trailing separator on the command's OWN last word is tolerated and consumed with the command, so
    // "insert new line," / ";" / "." all fire. Broader than the comma-only neighbour absorption because
    // the punctuation sits on the operator, not dictated content.
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
