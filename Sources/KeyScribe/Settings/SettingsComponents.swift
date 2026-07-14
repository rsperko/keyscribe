import SwiftUI

struct DisclosureSection<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    // A child needing attention must never sit hidden behind a collapsed header, so the section
    // auto-expands when either flag becomes true. If the user then manually re-collapses it, the header's
    // dot (colored to match the child's severity) keeps it reachable — mirroring the Settings sidebar.
    var hasError: Bool = false
    var hasWarning: Bool = false
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var needsAttention: Bool { hasError || hasWarning }
    private var showsAttentionDot: Bool { needsAttention && !isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack {
                    label()
                    Spacer()
                    if showsAttentionDot {
                        Circle().fill(hasError ? Color.red : Color.orange).frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(showsAttentionDot ? "Needs attention" : "")
            if isExpanded { content() }
        }
        // Only forces open — never auto-collapses — so the user can still close it, falling back to the dot.
        .onAppear { if needsAttention { isExpanded = true } }
        .onChange(of: needsAttention) { _, now in if now { isExpanded = true } }
    }
}

extension DisclosureSection where Label == Text {
    init(
        _ title: String, isExpanded: Binding<Bool>, hasError: Bool = false, hasWarning: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._isExpanded = isExpanded
        self.hasError = hasError
        self.hasWarning = hasWarning
        self.label = { Text(title) }
        self.content = content
    }
}

// Deliberately no leading glyph — the color alone carries severity (red = failure, orange = advisory);
// reachability is the red dot on the owning field's label/container. Multi-state status indicators
// (badges, the connection-test tri-state, permission rows) keep their icon set and are not this.
struct IssueText: View {
    enum Severity { case failure, advisory }
    let message: String
    var severity: Severity = .failure
    var font: Font = .caption

    init(_ message: String, severity: Severity = .failure, font: Font = .caption) {
        self.message = message
        self.severity = severity
        self.font = font
    }

    var body: some View {
        Text(message)
            .font(font)
            .foregroundStyle(severity == .failure ? Color.red : Color.orange)
            .accessibilityLabel("\(severity == .failure ? "Error" : "Warning"): \(message)")
    }
}

struct VocabularyFeedbackView: View {
    let feedback: VocabularyFeedback

    var body: some View {
        switch feedback {
        case .existing(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .update(let message):
            Label(message, systemImage: "info.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        case .advisory(let message):
            IssueText(message, severity: .advisory)
        }
    }
}

struct DisclosureSummaryLabel: View {
    let title: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// No hover-only tooltips for anything affecting data, privacy, or output (ui_design.md §3) — the "Learn
// more" disclosure and persistent dependency reason exist so that information is always reachable.
struct SettingRow<Control: View>: View {
    let title: String
    var result: String? = nil
    let help: String
    var dependencyReason: String? = nil
    @ViewBuilder var control: () -> Control
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() }
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

// Label strings come from KeyScribeKit (HistoryEntry); this one view is shared by HUD, Mode summaries,
// and History so data-boundary categories always render identically.
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

// Settings are modeless / immediate-apply (Apple HIG: no Save/Cancel/Apply/Done). Commits on Return or
// focus loss, not per keystroke, to avoid per-character disk writes + config-watcher churn. Esc reverts
// to the last committed value; the draft re-seeds from the model when it changes externally and the
// field isn't being edited.
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
            // A container teardown (`.id` swap, pane switch) can remove the field without a focus-loss commit.
            .onDisappear { commitIfChanged() }
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

// A popover's own onDisappear commit does NOT fire reliably on teardown, so the debounce alone can lose
// a just-typed edit to a fast Done; this lets the dismissing container flush synchronously first.
@MainActor final class PromptEditorFlush {
    var commit: (() -> Void)?
    func flush() { commit?() }
}

struct PromptEditor: View {
    let title: String
    let placeholder: String
    let text: String
    // Live commit (write on every change) is for an editor in a dismissing container like a popover:
    // TextEditor's focus-loss/onDisappear commit does NOT fire reliably when the container tears down on
    // Done, so per-change is the only dependable save there (plus the flush handle on Done). Inline
    // editors keep focus-loss commit to avoid per-keystroke config-watcher churn.
    let commitsOnChange: Bool
    let commit: (String) -> Void
    let flush: PromptEditorFlush?
    let expandID: String?
    let expandDoneID: String?
    @State private var draft: String
    @State private var expanded = false
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(
        title: String, placeholder: String = "", text: String,
        commitsOnChange: Bool = false, flush: PromptEditorFlush? = nil,
        expandID: String? = nil, expandDoneID: String? = nil,
        commit: @escaping (String) -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.text = text
        self.commitsOnChange = commitsOnChange
        self.flush = flush
        self.expandID = expandID
        self.expandDoneID = expandDoneID
        self.commit = commit
        _draft = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // TextEditor has no onSubmit (Return inserts a newline), so commit is driven by focus loss or
            // commitsOnChange instead.
            TextEditor(text: $draft)
                .font(.body)
                .ghostText(placeholder, visible: draft.isEmpty)
                .frame(minHeight: 120, maxHeight: 220)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .focused($focused)
                .onChange(of: draft) { if commitsOnChange { scheduleCommit() } }
                .onChange(of: focused) { _, nowFocused in if !nowFocused { commitNow() } }
                .onChange(of: text) { _, newValue in if !focused { draft = newValue } }
                .onAppear { flush?.commit = { commitNow() } }
                .onDisappear { commitNow() }
            Button("Open in a larger editor…") { expanded = true }
                .font(.caption).buttonStyle(.link)
                .accessibilityIdentifier(ifPresent: expandID)
        }
        .sheet(isPresented: $expanded) {
            PromptEditorSheet(title: title, placeholder: placeholder, text: $draft, doneID: expandDoneID) { commitNow() }
        }
    }

    private func commitIfChanged() { if draft != text { commit(draft) } }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            commitIfChanged()
        }
    }

    private func commitNow() {
        commitTask?.cancel()
        commitIfChanged()
    }
}

private struct PromptEditorSheet: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var doneID: String? = nil
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
                    .accessibilityIdentifier(ifPresent: doneID)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
    }
}

extension View {
    @ViewBuilder func accessibilityIdentifier(ifPresent id: String?) -> some View {
        if let id { accessibilityIdentifier(id) } else { self }
    }
}

// TextEditor, unlike TextField, has no native placeholder. Aligns with TextEditor's internal text inset
// and ignores hits so it never blocks typing.
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
