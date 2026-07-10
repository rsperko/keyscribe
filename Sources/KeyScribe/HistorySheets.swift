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
    private var replaceTrimmed: String { replace.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isNoop: Bool {
        !sourceTrimmed.isEmpty && sourceTrimmed.caseInsensitiveCompare(replaceTrimmed) == .orderedSame
    }
    private var canSave: Bool { !sourceTrimmed.isEmpty && !isNoop }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Replacement").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("When \(Branding.appName) hears").font(.caption).foregroundStyle(.secondary)
                TextField("The misheard words", text: $source)
                    .textFieldStyle(.roundedBorder).focused($focus, equals: .source).onSubmit { save() }
                    .accessibilityIdentifier(AccessibilityID.History.ReplacementSheet.source)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Replace with").font(.caption).foregroundStyle(.secondary)
                TextField("What it should say", text: $replace)
                    .textFieldStyle(.roundedBorder).focused($focus, equals: .replace).onSubmit { save() }
                    .accessibilityIdentifier(AccessibilityID.History.ReplacementSheet.replace)
            }
            if isNoop {
                Text("That is the same as what was heard, so it would do nothing.")
                    .font(.caption).foregroundStyle(.secondary)
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
        .onAppear { focus = sourceTrimmed.isEmpty ? .source : .replace }
    }

    private func save() {
        guard canSave else { return }
        onSave(sourceTrimmed, replaceTrimmed)
        dismiss()
    }
}

struct AddToDictionarySheet: View {
    let initialTerm: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @FocusState private var termFocused: Bool

    init(initialTerm: String, onSave: @escaping (String) -> Void) {
        self.initialTerm = initialTerm
        self.onSave = onSave
        _term = State(initialValue: initialTerm)
    }

    private var trimmed: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

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
            Text("Next time you say this, \(Branding.appName) will prefer your spelling. A phrase that is always misheard the same way works better as a Replacement, which changes it exactly.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Dictionary") { save() }
                    .keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
                    .accessibilityIdentifier(AccessibilityID.History.DictionarySheet.save)
            }
        }
        .padding(20).frame(width: 400)
        .onAppear { termFocused = true }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
