import AppKit
import KeyScribeKit
import SwiftUI

struct CreateReplacementSheet: View {
    let initialSource: String
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: String
    @State private var replace = ""
    @FocusState private var focus: Field?

    private enum Field { case source, replace }

    init(initialSource: String, onSave: @escaping (String, String) -> Void) {
        self.initialSource = initialSource
        self.onSave = onSave
        _source = State(initialValue: initialSource)
    }

    private var sourceTrimmed: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isNoop: Bool {
        !sourceTrimmed.isEmpty && sourceTrimmed.caseInsensitiveCompare(replace) == .orderedSame
    }
    private var sourceIssue: UserInputValidation.Issue? { UserInputValidation.phraseIssue(sourceTrimmed) }
    private var isOverLimit: Bool { !ReplacementAuthoring.isWithinLimit(replace) }
    private var canSave: Bool { sourceIssue == nil && !isOverLimit && !isNoop }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Replacement").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("When \(Branding.appName) hears").font(.caption).foregroundStyle(.secondary)
                TextField("The misheard words", text: $source)
                    .textFieldStyle(.roundedBorder).focused($focus, equals: .source).onSubmit { save() }
                    .accessibilityIdentifier(AccessibilityID.History.ReplacementSheet.source)
            }
            if let sourceIssue { IssueText(sourceIssue.message) }
            VStack(alignment: .leading, spacing: 4) {
                Text("Replace with").font(.caption).foregroundStyle(.secondary)
                ReplacementValueField(
                    title: "Replace with",
                    placeholder: "What it should say",
                    text: $replace,
                    fieldID: AccessibilityID.History.ReplacementSheet.replace,
                    initiallyFocused: !sourceTrimmed.isEmpty,
                    onSubmit: save)
            }
            if isNoop {
                Text("That is the same as what was heard, so it would do nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ReplacementLimitIssueText(issue: isOverLimit ? .tooLong : nil)
            if let message = VocabularyDraftAnalysis.invisibleOnlyDescription(replace) {
                IssueText(message, severity: .advisory)
            }
            Text("Applies to future dictations in every mode that uses replacements.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Replacement") { save() }
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
                    .accessibilityIdentifier(AccessibilityID.History.ReplacementSheet.save)
            }
        }
        .padding(20).frame(width: 400)
        .onAppear { if sourceTrimmed.isEmpty { focus = .source } }
    }

    private func save() {
        guard canSave else { return }
        onSave(sourceTrimmed, replace)
        dismiss()
    }
}

struct AddToDictionarySheet: View {
    let initialTerm: String
    let analyze: (VocabularyProposal) -> VocabularyAnalysis
    let onSave: (String, VocabularyAnalysis.Action) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @FocusState private var termFocused: Bool

    init(
        initialTerm: String,
        analyze: @escaping (VocabularyProposal) -> VocabularyAnalysis,
        onSave: @escaping (String, VocabularyAnalysis.Action) -> Void
    ) {
        self.initialTerm = initialTerm
        self.analyze = analyze
        self.onSave = onSave
        _term = State(initialValue: initialTerm)
    }

    private var trimmed: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draft: VocabularyDraftAnalysis {
        VocabularyDraftAnalysis(term: trimmed, replacement: "", regex: false, analyze: analyze)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Dictionary").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Word or term").font(.caption).foregroundStyle(.secondary)
                TextField("A name, product term, or jargon", text: $term)
                    .textFieldStyle(.roundedBorder).focused($termFocused)
                    .onSubmit { save() }
                    .accessibilityIdentifier(AccessibilityID.History.DictionarySheet.term)
            }
            if case let .invalidInput(issue) = draft.validationIssue { IssueText(issue.message) }
            if let feedback = draft.feedback {
                VocabularyFeedbackView(feedback: feedback)
                    .accessibilityIdentifier(AccessibilityID.History.DictionarySheet.status)
            }
            Text("Next time you say this, \(Branding.appName) will prefer your spelling. A phrase that is always misheard the same way works better as a Replacement, which changes it exactly.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.buttonTitle) { save() }
                    .keyboardShortcut(.defaultAction).disabled(!draft.canCommit)
                    .accessibilityIdentifier(AccessibilityID.History.DictionarySheet.save)
            }
        }
        .padding(20).frame(width: 400)
        .onAppear { termFocused = true }
    }

    private func save() {
        guard draft.canCommit,
              case let .word(word) = draft.proposal,
              let action = draft.analysis?.action
        else { return }
        onSave(word, action)
        dismiss()
    }
}
