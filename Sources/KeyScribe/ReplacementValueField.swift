import KeyScribeKit
import SwiftUI

struct ReplacementExpandedEditorIDs {
    let expand: String
    let editor: String
    let done: String
}

struct ReplacementValueField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let fieldID: String
    var initiallyFocused = false
    var onSubmit: (() -> Void)?

    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder), axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(title)
            .accessibilityIdentifier(fieldID)
            .focused($focused)
            .onSubmit { onSubmit?() }
        .onAppear { if initiallyFocused { focused = true } }
        .onChange(of: text) { _, newValue in
            let normalized = ReplacementAuthoring.normalizingLineEndings(newValue)
            if normalized != newValue { text = normalized }
        }
    }
}

struct ReplacementExpandedEditorButton: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let ids: ReplacementExpandedEditorIDs
    @State private var expanded = false

    var body: some View {
        Button("Open in a larger editor…") { expanded = true }
            .font(.caption)
            .buttonStyle(.link)
            .accessibilityIdentifier(ids.expand)
            .sheet(isPresented: $expanded) {
                ReplacementEditorSheet(
                    title: title,
                    placeholder: placeholder,
                    text: $text,
                    ids: ids)
            }
    }
}

struct ReplacementTextEditor: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let editorID: String
    var minHeight: CGFloat = 180

    private var overflow: Int { text.count - ReplacementAuthoring.maxCharacters }
    private var isOverLimit: Bool { overflow > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.body)
                .ghostText(placeholder, visible: text.isEmpty)
                .frame(minHeight: minHeight)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isOverLimit ? Color.red : Color(nsColor: .separatorColor)))
                .accessibilityLabel(title)
                .accessibilityIdentifier(editorID)
            HStack(alignment: .firstTextBaseline) {
                if isOverLimit {
                    IssueText("Too long by \(overflow.formatted()) characters. Shorten it to save.")
                }
                Spacer()
                Text("\(text.count.formatted()) / \(ReplacementAuthoring.maxCharacters.formatted())")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(isOverLimit ? Color.red : Color.secondary)
            }
        }
        .onChange(of: text) { _, newValue in
            let normalized = ReplacementAuthoring.normalizingLineEndings(newValue)
            if normalized != newValue { text = normalized }
        }
    }
}

private struct ReplacementEditorSheet: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let ids: ReplacementExpandedEditorIDs
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ReplacementTextEditor(
                title: title,
                placeholder: placeholder,
                text: $text,
                editorID: ids.editor,
                minHeight: 320)
                .frame(minWidth: 480)
            HStack {
                Text("Done returns this text to the form — it is saved when you add or update the replacement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(ids.done)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
    }
}

struct VocabularyDraftIssueText: View {
    let issue: VocabularyDraftValidationIssue?

    var body: some View {
        switch issue {
        case .invalidRegex:
            IssueText("That is not a valid regular expression.")
        case .unsafePattern:
            IssueText("This pattern repeats a group that can itself repeat (like (a+)+), which can make matching too slow. Simplify it to save.")
        case .replacementRequired:
            IssueText("Use instead is required for a regular expression.")
        case .invalidInput(let issue):
            IssueText(issue.message)
        case .tooLong:
            IssueText("Too long — shorten it to \(ReplacementAuthoring.maxCharacters.formatted()) characters or fewer to save.")
        case .nonTerminalReturnMarker:
            IssueText("A <CR> can only go at the very end. Write \\<CR> to insert the literal text “<CR>”.")
        case nil:
            EmptyView()
        }
    }
}
