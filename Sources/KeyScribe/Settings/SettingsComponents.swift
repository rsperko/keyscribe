import SwiftUI

struct DisclosureSection<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack {
                    label()
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded { content() }
        }
    }
}

extension DisclosureSection where Label == Text {
    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self._isExpanded = isExpanded
        self.label = { Text(title) }
        self.content = content
    }
}

// ui_components.md "Setting row with help": label + one-line result, the control, an inline
// Learn more disclosure carrying benefit/limit/prerequisite, plus a
// persistent dependency reason when the control is gated. No hover-only tooltips for anything
// that affects data, privacy, or output (ui_design.md §3).
struct SettingRow<Control: View>: View {
    let title: String
    var result: String? = nil
    let help: String
    var dependencyReason: String? = nil
    @ViewBuilder var control: () -> Control
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                control()
            }
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(expanded ? "Hide details" : "Learn more")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if expanded {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
            if let dependencyReason {
                Label(dependencyReason, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, result].compactMap { $0 }.joined(separator: ", "))
    }
}

// ui_components.md data-boundary badge: one shared capsule for "On this Mac", "Cloud rewrite",
// "Best-effort redaction", "App shared", "Selected text shared". The label
// strings come from KeyScribeKit (HistoryEntry); this is the single view used in HUD, Mode
// summaries, and History so the categories never collapse into a generic "context" label.
struct DataBoundaryBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel(label)
    }
}

// Settings are modeless / immediate-apply (Apple HIG: a Settings window has no Save/Cancel/Apply/
// Done). A text field, though, should apply on END-OF-EDITING — Return or focus loss — not on every
// keystroke, which is the native AppKit commit point and avoids per-character disk writes + config-
// watcher churn. Esc reverts the in-progress edit to the last committed value (the per-field "cancel").
// The draft re-seeds from the model when it changes externally and the field is not being edited.
struct CommittedTextField: View {
    let title: String
    let text: String
    let prompt: String?
    let autofocus: Bool
    let commit: (String) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool

    init(
        _ title: String, text: String, prompt: String? = nil,
        autofocus: Bool = false, commit: @escaping (String) -> Void
    ) {
        self.title = title
        self.text = text
        self.prompt = prompt
        self.autofocus = autofocus
        self.commit = commit
        _draft = State(initialValue: text)
    }

    var body: some View {
        Group {
            if let prompt {
                TextField(title, text: $draft, prompt: Text(prompt))
            } else {
                TextField(title, text: $draft)
            }
        }
            .focused($focused)
            .onSubmit { commitIfChanged() }
            .onExitCommand { draft = text }
            .onChange(of: focused) { _, nowFocused in if !nowFocused { commitIfChanged() } }
            .onChange(of: text) { _, newValue in if !focused { draft = newValue } }
            .onAppear {
                guard autofocus else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    focused = true
                }
            }
    }

    private func commitIfChanged() { if draft != text { commit(draft) } }
}

struct PromptEditor: View {
    let title: String
    let placeholder: String
    let text: String
    // Live commit (write on every change) is for an editor that lives in a dismissing container like a
    // popover: TextEditor's focus-loss/onDisappear commit does NOT fire reliably when the container is
    // torn down on Done, so the only dependable save is per-change. Inline editors (the writing
    // instruction in the form) keep focus-loss to avoid per-keystroke config-watcher churn.
    let commitsOnChange: Bool
    let commit: (String) -> Void
    @State private var draft: String
    @State private var expanded = false
    @FocusState private var focused: Bool

    init(
        title: String, placeholder: String = "", text: String,
        commitsOnChange: Bool = false, commit: @escaping (String) -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.text = text
        self.commitsOnChange = commitsOnChange
        self.commit = commit
        _draft = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // TextEditor has no onSubmit (Return inserts a newline), so an inline editor commits on
            // focus loss; a popover editor commits live (see commitsOnChange).
            TextEditor(text: $draft)
                .font(.body)
                .ghostText(placeholder, visible: draft.isEmpty)
                .frame(minHeight: 120, maxHeight: 220)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .focused($focused)
                .onChange(of: draft) { if commitsOnChange { commitIfChanged() } }
                .onChange(of: focused) { _, nowFocused in if !nowFocused { commitIfChanged() } }
                .onChange(of: text) { _, newValue in if !focused { draft = newValue } }
            Button("Open in a larger editor…") { expanded = true }
                .font(.caption).buttonStyle(.link)
        }
        .sheet(isPresented: $expanded) {
            PromptEditorSheet(title: title, placeholder: placeholder, text: $draft) { commitIfChanged() }
        }
    }

    private func commitIfChanged() { if draft != text { commit(draft) } }
}

private struct PromptEditorSheet: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .ghostText(placeholder, visible: text.isEmpty)
                .frame(minWidth: 480, minHeight: 360)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Done") { onDone(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
    }
}

// Ghost text for TextEditor, which (unlike TextField) has no native placeholder. Aligns with
// TextEditor's internal text inset and ignores hits so it never blocks typing.
extension View {
    func ghostText(_ placeholder: String, visible: Bool) -> some View {
        overlay(alignment: .topLeading) {
            if visible && !placeholder.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
        }
    }
}
