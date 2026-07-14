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
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let proposal: VocabularyProposal?
        if term.isEmpty {
            proposal = nil
            validationIssue = nil
        } else if regex && !RegexCache.isValidPattern(term) {
            proposal = nil
            validationIssue = .invalidRegex
        } else if regex && replacement.isEmpty {
            proposal = nil
            validationIssue = .replacementRequired
        } else if regex {
            proposal = .replacement(heard: term, replace: replacement, regex: true)
            validationIssue = nil
        } else if replacement.isEmpty && !requiresReplacement {
            proposal = .word(term)
            validationIssue = nil
        } else {
            proposal = .replacement(heard: term, replace: replacement, regex: false)
            validationIssue = nil
        }
        self.proposal = proposal
        let analysis = proposal.map(analyze)
        self.analysis = analysis
        self.feedback = Self.feedback(for: analysis, term: term)
    }

    var canCommit: Bool {
        guard proposal != nil else { return false }
        if case .noChange = analysis?.action { return false }
        return true
    }

    var canApplyCorrection: Bool { proposal != nil }

    var isUpdate: Bool {
        if case .updateReplacement = analysis?.action { return true }
        return false
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

    private static func feedback(for analysis: VocabularyAnalysis?, term: String) -> VocabularyFeedback? {
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
        case .addWord, .addReplacement:
            guard let message = analysis.advisories.first(where: { $0.kind == .overridesGlobal })?.message else {
                return nil
            }
            return .advisory(message)
        }
    }
}
