import Foundation
import KeyScribeKit

enum VocabularyFeedback: Equatable {
    case existing(String)
    case update(String)
    case advisory(String)
}

enum VocabularyDraftValidationIssue: Equatable {
    case invalidRegex
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
            validationIssue = regex && termIssue == .invalidRegex ? .invalidRegex : .invalidInput(termIssue)
        } else if regex && !RegexCache.isValidPattern(term) {
            proposal = nil
            validationIssue = .invalidRegex
        } else if regex && replacement.isEmpty {
            proposal = nil
            validationIssue = .replacementRequired
        } else if replacement.isEmpty && !requiresReplacement {
            proposal = .word(term)
            validationIssue = nil
        } else if !ReplacementAuthoring.isWithinLimit(replacement) {
            proposal = nil
            validationIssue = .tooLong
        } else if regex && !ReplacementAuthoring.regexReturnMarkerValid(replacement) {
            proposal = nil
            validationIssue = .nonTerminalReturnMarker
        } else {
            proposal = .replacement(heard: term, replace: replacement, regex: false)
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

    var buttonTitle: String {
        isUpdate ? "Update" : "Add"
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
            let current = current.isEmpty ? "nothing" : "“\(current)”"
            return .update("Updates the existing replacement — “\(term)” currently becomes \(current).")
        case .updateWord(let current):
            return .update("Updates the existing word — “\(term)” is currently spelled “\(current)”.")
        case .addWord, .addReplacement:
            if case let .replacement(_, replace, _) = proposal,
               let invisible = Self.invisibleOnlyDescription(replace) {
                return .advisory(invisible)
            }
            guard let message = analysis.advisories.first(where: { $0.kind == .overridesGlobal })?.message else {
                return nil
            }
            return .advisory(message)
        }
    }
}
