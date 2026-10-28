import Foundation
import KeyScribeKit

enum VocabularyFeedback: Equatable {
    case existing(String)
    case update(String)
    case advisory(String)
}

enum VocabularyDraftValidationIssue: Equatable {
    case invalidRegex
    case unsafePattern
    case replacementRequired
    case invalidInput(UserInputValidation.Issue)
    case tooLong
    case nonTerminalReturnMarker
}

struct VocabularyDraftAnalysis {
    let proposal: VocabularyProposal?
    let analysis: VocabularyAnalysis?
    let feedback: VocabularyFeedback?
    let validationIssue: VocabularyDraftValidationIssue?

    init(
        term: String, replacement: String, regex: Bool,
        analyze: (VocabularyProposal) -> VocabularyAnalysis
    ) {
        self.init(
            term: term, replacement: replacement, regex: regex,
            requiresReplacement: false, analyze: analyze)
    }

    init(
        replacementTerm term: String, replacement: String, regex: Bool,
        analyze: (VocabularyProposal) -> VocabularyAnalysis
    ) {
        self.init(
            term: term, replacement: replacement, regex: regex,
            requiresReplacement: true, analyze: analyze)
    }

    private init(
        term: String, replacement: String, regex: Bool, requiresReplacement: Bool,
        analyze: (VocabularyProposal) -> VocabularyAnalysis
    ) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposal: VocabularyProposal?
        let termIssue = regex
            ? UserInputValidation.regexIssue(term)
            : UserInputValidation.phraseIssue(term)
        if term.isEmpty {
            proposal = nil
            validationIssue = nil
        } else if let termIssue {
            proposal = nil
            switch termIssue {
            case .invalidRegex:
                validationIssue = .invalidRegex
            case .unsafeRegex:
                validationIssue = .unsafePattern
            default:
                validationIssue = .invalidInput(termIssue)
            }
        } else if regex && replacement.isEmpty {
            proposal = nil
            validationIssue = .replacementRequired
        } else if replacement.isEmpty && !requiresReplacement {
            proposal = .word(term)
            validationIssue = nil
        } else if let replacementIssue = Self.replacementValidationIssue(replacement) {
            proposal = nil
            validationIssue = replacementIssue
        } else if regex && !ReplacementAuthoring.regexReturnMarkerValid(replacement) {
            proposal = nil
            validationIssue = .nonTerminalReturnMarker
        } else {
            proposal = .replacement(heard: term, replace: replacement, regex: regex)
            validationIssue = nil
        }
        self.proposal = proposal
        let analysis = proposal.map(analyze)
        self.analysis = analysis
        self.feedback = Self.feedback(for: analysis, proposal: proposal, term: term)
    }

    var canCommit: Bool {
        guard proposal != nil else { return false }
        if case .noChange = analysis?.action { return false }
        return true
    }

    var canApplyCorrection: Bool { proposal != nil }

    var isUpdate: Bool {
        switch analysis?.action {
        case .updateWord, .updateReplacement: true
        default: false
        }
    }

    // Says what the button will save, so a filled or empty Use instead is never a guess.
    var buttonTitle: String {
        let verb = isUpdate ? "Update" : "Add"
        switch proposal {
        case .word: return "\(verb) Word"
        case .replacement: return "\(verb) Replacement"
        case nil: return verb
        }
    }

    func replacementSummary(in destination: CorrectionDestination) -> String? {
        guard case let .replacement(heard, replace, regex) = proposal else { return nil }
        let place = switch destination.scope {
        case .global: "modes that include Global vocabulary"
        case .mode: destination.title
        }
        let what = regex ? "matches of “\(heard)”" : "“\(heard)”"
        return "Replace \(what) with “\(ReplacementAuthoring.preview(for: replace).text)” in \(place)."
    }

    static func isAlreadyAdded(_ action: VocabularyAnalysis.Action?) -> Bool {
        guard case .noChange(let reason)? = action else { return false }
        return reason == .wordAlreadyListed || reason == .wordCoveredByGlobal
    }

    // The selected words were a known name misheard: adding the name again does nothing, but correcting that
    // spelling from now on is what the user came for.
    static func teachableCorrection(
        selected: String, term: String, action: VocabularyAnalysis.Action?
    ) -> (heard: String, word: String)? {
        guard isAlreadyAdded(action) else { return nil }
        let heard = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, heard.caseInsensitiveCompare(term) != .orderedSame else { return nil }
        return (heard, term)
    }

    var replacementRule: ReplacementsSet.Rule? {
        guard case let .replacement(heard, replace, regex) = proposal else { return nil }
        return ReplacementsSet.Rule(heard: heard, replace: replace, regex: regex)
    }

    var hasReplacementIdentityConflict: Bool {
        switch analysis?.action {
        case .updateReplacement, .noChange: true
        default: false
        }
    }

    func canUpdateReplacement(from original: ReplacementsSet.Rule) -> Bool {
        guard let replacementRule else { return false }
        return replacementRule != original && !hasReplacementIdentityConflict
    }

    static func replacementValidationIssue(_ replacement: String) -> VocabularyDraftValidationIssue? {
        guard ReplacementAuthoring.isWithinLimit(replacement) else { return .tooLong }
        guard let issue = UserInputValidation.promptIssue(replacement) else { return nil }
        return .invalidInput(issue)
    }

    static func invisibleOnlyDescription(_ replace: String) -> String? {
        guard !replace.isEmpty, replace.allSatisfy(\.isWhitespace) else { return nil }
        let lineBreaks = replace.reduce(0) { $0 + ($1.isNewline ? 1 : 0) }
        if lineBreaks > 0 {
            let plural = lineBreaks == 1 ? "" : "s"
            return "Creates a replacement containing \(lineBreaks) line break\(plural)."
        }
        return "Creates a replacement containing only whitespace."
    }

    private static func feedback(
        for analysis: VocabularyAnalysis?, proposal: VocabularyProposal?, term: String
    ) -> VocabularyFeedback? {
        guard let analysis else { return nil }
        switch analysis.action {
        case .noChange(.wordAlreadyListed):
            return .existing("Already in Words to Recognize.")
        case .noChange(.wordCoveredByGlobal):
            return .existing("Already included from your global vocabulary.")
        case .noChange(.replacementAlreadyListed):
            return .existing("Already in Automatic Replacements.")
        case .noChange(.replacementCoveredByGlobal):
            return .existing("Already included from your global replacements.")
        case .updateReplacement(let current):
            let current = current.isEmpty
                ? "nothing"
                : "“\(ReplacementAuthoring.preview(for: current).text)”"
            return .update("Updates the existing replacement — “\(term)” currently becomes \(current).")
        case .updateWord(let current):
            return .update("Updates the existing word — “\(term)” is currently spelled “\(current)”.")
        case .addWord, .addReplacement:
            if let message = analysis.advisories.first(where: { $0.kind == .overridesGlobal })?.message {
                return .advisory(message)
            }
            if case let .replacement(_, replace, regex) = proposal {
                if let literal = ReplacementAuthoring.literalReturnMarkerAdvisory(replace: replace, regex: regex) {
                    return .advisory(literal)
                }
                if let invisible = Self.invisibleOnlyDescription(replace) {
                    return .advisory(invisible)
                }
            }
            return nil
        }
    }
}
