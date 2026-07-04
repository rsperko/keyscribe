import Foundation

// Pure assertion model for the `--commands-check` dev harness. The harness transcribes recorded
// audio, runs the real local dictation pipeline, and hands each case's final output here to check
// that a spoken command behaved. Assertions are declarative data (a manifest row), so exercising a
// new command is adding a case, not code (principles.md §2). Matching for presence/absence is
// case-insensitive — STT casing varies (a sentence-initial "Insert new line" vs mid-utterance
// "insert new line"), and "was the trigger phrase consumed" must not hinge on how the engine cased
// it; `equals` stays exact because a whole-utterance replacement's output is generated, not heard.
public enum CommandCheck {
    public struct Assertion: Equatable, Sendable, Decodable {
        // Substrings that MUST appear (the inserted control char, clipboard value, or a literal that
        // proves a command did NOT fire).
        public var contains: [String]
        // Substrings that MUST be absent (a consumed trigger phrase, or text "scratch that" removed).
        public var absent: [String]
        // The whole output must equal this (a whole-utterance replacement's generated value).
        public var equals: String?
        // This value must appear with no sentence/clause punctuation immediately before it (the
        // spurious-terminator-before-paste artifact the clipboard fold removes).
        public var noLeadingPunct: String?

        public init(
            contains: [String] = [], absent: [String] = [],
            equals: String? = nil, noLeadingPunct: String? = nil
        ) {
            self.contains = contains
            self.absent = absent
            self.equals = equals
            self.noLeadingPunct = noLeadingPunct
        }

        enum CodingKeys: String, CodingKey { case contains, absent, equals, noLeadingPunct }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            contains = try c.decodeIfPresent([String].self, forKey: .contains) ?? []
            absent = try c.decodeIfPresent([String].self, forKey: .absent) ?? []
            equals = try c.decodeIfPresent(String.self, forKey: .equals)
            noLeadingPunct = try c.decodeIfPresent(String.self, forKey: .noLeadingPunct)
        }
    }

    public struct Outcome: Equatable, Sendable {
        public let passed: Bool
        public let failures: [String]
    }

    public static func evaluate(output: String, assertion: Assertion) -> Outcome {
        var failures: [String] = []
        for needle in assertion.contains where !needle.isEmpty
        && output.range(of: needle, options: .caseInsensitive) == nil {
            failures.append("missing \(display(needle))")
        }
        for needle in assertion.absent where !needle.isEmpty
        && output.range(of: needle, options: .caseInsensitive) != nil {
            failures.append("survived \(display(needle))")
        }
        if let expected = assertion.equals, output != expected {
            failures.append("expected exactly \(display(expected)), got \(display(output))")
        }
        if let value = assertion.noLeadingPunct, hasLeadingPunct(before: value, in: output) {
            failures.append("punctuation before \(display(value))")
        }
        return Outcome(passed: failures.isEmpty, failures: failures)
    }

    // True if the char immediately before `value` (skipping one run of spaces) is sentence or clause
    // punctuation. Locates `value` case-insensitively; a value absent from the text is not an artifact.
    static func hasLeadingPunct(before value: String, in text: String) -> Bool {
        guard let r = text.range(of: value, options: .caseInsensitive) else { return false }
        var i = r.lowerBound
        while i > text.startIndex {
            let prev = text.index(before: i)
            if text[prev] == " " { i = prev } else { return ".,;:!?".contains(text[prev]) }
        }
        return false
    }

    static func display(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
}

// Release-gate view over a whole `--commands-check` run: one row per engine the harness attempted.
// The pass rule is the pure decision the CLI's exit code keys off, so a spoken-command regression
// fails the preflight instead of merely printing a ✗ nobody reads.
public struct CommandCheckReport: Equatable, Sendable {
    public struct Engine: Equatable, Sendable {
        public let id: String
        public let clean: Int
        public let total: Int
        public let loaded: Bool
        public init(id: String, clean: Int, total: Int, loaded: Bool) {
            self.id = id
            self.clean = clean
            self.total = total
            self.loaded = loaded
        }
    }

    public var engines: [Engine]
    public init(engines: [Engine]) { self.engines = engines }

    // Guards against a green result that only means "nothing ran": a missing corpus or uninstalled
    // models must not read as a pass.
    public var ranCount: Int { engines.filter { $0.loaded && $0.total > 0 }.count }

    public func diff(against baseline: CommandCheckBaseline) -> CommandCheckDiff {
        var regressions: [CommandCheckDiff.Change] = []
        var stale: [String] = []
        for e in engines where e.loaded && e.total > 0 {
            guard let base = baseline.engines[e.id] else { continue }  // a newly-installed engine is not a regression
            if e.total != base.total { stale.append(e.id); continue }  // corpus changed under the baseline → re-baseline
            if e.clean < base.clean {
                regressions.append(.init(id: e.id, baseline: base.clean, current: e.clean, total: e.total))
            }
        }
        return CommandCheckDiff(regressions: regressions, stale: stale, ranCount: ranCount)
    }
}

// A per-engine record of how many command checks were clean on a known-good run. Ground truth, not a
// guessed threshold: the corpus clips are transcription-sensitive, so no absolute pass-rate is
// meaningful across engines (a weak engine that mishears "scratch that" fails a clip its WER, not a
// bug). "This clip passed on this engine last time" is the real bar; the gate flags only a *drop*.
public struct CommandCheckBaseline: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var clean: Int
        public var total: Int
        public init(clean: Int, total: Int) { self.clean = clean; self.total = total }
    }
    public var engines: [String: Entry]
    public init(engines: [String: Entry]) { self.engines = engines }

    public static func from(_ report: CommandCheckReport) -> CommandCheckBaseline {
        var e: [String: Entry] = [:]
        for eng in report.engines where eng.loaded && eng.total > 0 {
            e[eng.id] = Entry(clean: eng.clean, total: eng.total)
        }
        return CommandCheckBaseline(engines: e)
    }
}

public struct CommandCheckDiff: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        public let id: String
        public let baseline: Int
        public let current: Int
        public let total: Int
    }
    public var regressions: [Change]
    // Engines whose clip count no longer matches the baseline — the corpus changed, so re-baseline.
    public var stale: [String]
    public var ranCount: Int

    public var passed: Bool { regressions.isEmpty && stale.isEmpty && ranCount > 0 }
}
