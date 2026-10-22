import AppKit
import SwiftUI
import KeyScribeKit

enum SettingsMetrics {
    // The trailing value column's control width, shared so controls line up as one column instead of
    // agreeing by coincidence.
    static let valueControlWidth: CGFloat = 240
    // A slider's min/max value labels sit INSIDE its frame, so matching valueControlWidth exactly leaves a
    // visibly shorter track than the wells beside it. The extra 20% buys the track back and then some.
    static let volumeSliderWidth: CGFloat = valueControlWidth * 1.2
}

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

@MainActor
func requiredLabel(_ text: String) -> some View {
    IssueText(text, severity: .advisory)
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
    var combinesAccessibilityChildren = true
    @ViewBuilder var control: () -> Control
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if combinesAccessibilityChildren {
            content.accessibilityElement(children: .combine)
        } else {
            content.accessibilityElement(children: .contain)
        }
    }

    private var content: some View {
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
    let validation: ((String) -> UserInputValidation.Issue?)?
    let commit: (String) -> Void
    @State private var draft: String
    @State private var validationIssue: UserInputValidation.Issue?
    @FocusState private var focused: Bool

    init(
        _ title: String, text: String, prompt: String? = nil,
        autofocus: Bool = false, validation: ((String) -> UserInputValidation.Issue?)? = nil,
        commit: @escaping (String) -> Void
    ) {
        self.title = title
        self.text = text
        self.prompt = prompt
        self.autofocus = autofocus
        self.validation = validation
        self.commit = commit
        _draft = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let prompt {
                TextField(title, text: $draft, prompt: Text(prompt))
                    .multilineTextAlignment(.leading)
            } else {
                TextField(title, text: $draft)
                    .multilineTextAlignment(.leading)
            }
            if let validationIssue {
                IssueText(validationIssue.message)
            }
        }
            .focused($focused)
            .onSubmit { commitIfChanged() }
            .onExitCommand { draft = text; validationIssue = nil }
            .onChange(of: focused) { _, nowFocused in if !nowFocused { commitIfChanged() } }
            .onChange(of: text) { _, newValue in if !focused { draft = newValue; validationIssue = nil } }
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

    private func commitIfChanged() {
        guard draft != text else { return }
        if let issue = validation?(draft) {
            validationIssue = issue
            return
        }
        validationIssue = nil
        commit(draft)
    }
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
    @State private var validationIssue: UserInputValidation.Issue?
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
                .multilineTextAlignment(.leading)
                .ghostText(placeholder, visible: draft.isEmpty)
                .frame(minHeight: 120, maxHeight: 220)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .focused($focused)
                .onChange(of: draft) { if commitsOnChange { scheduleCommit() } }
                .onChange(of: focused) { _, nowFocused in if !nowFocused { _ = commitNow() } }
                .onChange(of: text) { _, newValue in if !focused { draft = newValue } }
                .onAppear { flush?.commit = { _ = commitNow() } }
                .onDisappear { _ = commitNow() }
            Button("Open in a larger editor…") { expanded = true }
                .font(.caption).buttonStyle(.link)
                .accessibilityIdentifier(ifPresent: expandID)
            if let validationIssue {
                IssueText(validationIssue.message)
            }
        }
        .sheet(isPresented: $expanded) {
            PromptEditorSheet(title: title, placeholder: placeholder, text: $draft, doneID: expandDoneID) { commitNow() }
        }
    }

    private func commitIfChanged() -> Bool {
        guard draft != text else { return true }
        if let issue = UserInputValidation.promptIssue(draft) {
            validationIssue = issue
            return false
        }
        validationIssue = nil
        commit(draft)
        return true
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            _ = commitIfChanged()
        }
    }

    private func commitNow() -> Bool {
        commitTask?.cancel()
        return commitIfChanged()
    }
}

private struct PromptEditorSheet: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var doneID: String? = nil
    let onDone: () -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .ghostText(placeholder, visible: text.isEmpty)
                .frame(minWidth: 480, minHeight: 360)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Done") { if onDone() { dismiss() } }.keyboardShortcut(.defaultAction)
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

// An operation or file failure for a pane. Field validation stays beside its field; this is for what the
// user tried to do (or a file the pane could not read), shown where scrolling can never hide it.
struct PaneNotice: Equatable, Identifiable {
    var title: String
    var message: String = ""
    var severity: IssueText.Severity = .failure
    var details: String? = nil
    var fileURL: URL? = nil

    var id: String { "\(title)|\(message)" }

    init(title: String, message: String = "", severity: IssueText.Severity = .failure,
         details: String? = nil, fileURL: URL? = nil) {
        self.title = title
        self.message = message
        self.severity = severity
        self.details = details
        self.fileURL = fileURL
    }

    init(issue: ConfigFileIssue, fileURL: URL?, consequence: String? = nil) {
        let parts = [issue.explanation, issue.isError ? nil : issue.detail, consequence ?? issue.recovery]
        self.init(
            title: issue.title, message: parts.compactMap { $0 }.joined(separator: " "),
            severity: issue.isError ? .failure : .advisory,
            details: issue.isError ? issue.technicalDetails : nil,
            fileURL: fileURL)
    }

    // Outcome first: the title says what didn't happen, the message which file needs fixing and what still
    // works. The parser's text and position stay in Technical details. A failure that isn't about the file
    // (a write refused by the system) says what the system said.
    static func failure(
        _ title: String, error: Error, file: URL, relativePath: String, stillRunning: String?
    ) -> PaneNotice {
        let configError = (error as? ConfigError) ?? (error as? ConfigRepository.UnreadableModeFile)?.error
        guard let configError else { return PaneNotice(title: title, message: error.localizedDescription) }
        let issue = ConfigFileIssue.unreadable(
            file.lastPathComponent, relativePath: relativePath, error: configError, recovery: .ignored)
        return PaneNotice(
            title: title, message: ["\(relativePath) needs fixing.", stillRunning].compactMap { $0 }.joined(separator: " "),
            details: issue.technicalDetails, fileURL: file)
    }

    static func unreadableFile(
        _ relativePath: String, error: ConfigError, file: URL, stillRunning: String?, here: String
    ) -> PaneNotice {
        let issue = ConfigFileIssue.unreadable(
            file.lastPathComponent, relativePath: relativePath, error: error, recovery: .ignored)
        return PaneNotice(
            title: "\(relativePath) needs fixing", message: [stillRunning, here].compactMap { $0 }.joined(separator: " "),
            details: issue.technicalDetails, fileURL: file)
    }

    // Only a recorded previous version earns "still working"; with no record, say nothing.
    static func stillRunning(_ state: ConfigFileIssue.Recovery?, working: String, off: String) -> String? {
        switch state {
        case .previousVersion: working
        case .ignored, .defaults: off
        case nil: nil
        }
    }
}

// Sits above a pane's Form, ScrollView, or list/detail split — never inside it.
struct PaneNoticeBanner: View {
    let notices: [PaneNotice]

    static let visibleLimit = 2
    static let maxHeight: CGFloat = 220
    @State private var showsAll = false
    @State private var contentHeight: CGFloat = 0

    // Exactly as tall as its content up to maxHeight, then it scrolls: a bare ScrollView would take the
    // whole cap even for one line, and an unbounded stack could push the pane's editor out of the window.
    var body: some View {
        if !notices.isEmpty {
            ScrollView {
                content
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: PaneNoticeHeightKey.self, value: proxy.size.height)
                    })
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), Self.maxHeight))
            .onPreferenceChange(PaneNoticeHeightKey.self) { contentHeight = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Settings.paneNotice)
            Divider()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(showsAll ? notices[...] : notices.prefix(Self.visibleLimit)) { PaneNoticeRow(notice: $0) }
            if notices.count > Self.visibleLimit {
                let more = notices.count - Self.visibleLimit
                Button(showsAll ? "Show fewer" : (more == 1 ? "Show 1 more problem" : "Show \(more) more problems")) {
                    showsAll.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}

private struct PaneNoticeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PaneNoticeRow: View {
    let notice: PaneNotice
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            IssueText(notice.title, severity: notice.severity, font: .callout)
            if !notice.message.isEmpty {
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let fileURL = notice.fileURL {
                Button("Show in Finder") {
                    let exists = FileManager.default.fileExists(atPath: fileURL.path)
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [exists ? fileURL : fileURL.deletingLastPathComponent()])
                }
                .accessibilityIdentifier(AccessibilityID.Settings.paneNoticeReveal)
            }
            if let details = notice.details, !details.isEmpty {
                DisclosureSection(isExpanded: $showsDetails) {
                    Text("Technical details").font(.caption)
                } content: {
                    Text(details)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
