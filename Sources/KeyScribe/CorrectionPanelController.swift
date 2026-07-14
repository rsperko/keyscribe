import AppKit
import KeyScribeKit
import SwiftUI

// The standalone correction surfaces (design.md §4.7): a panel to add a dictionary term or replacement without
// opening Settings. The Heard/term field is pre-filled best-effort from the current selection, captured before
// KeyScribe activates so the synthetic ⌘C still reaches the app the user was working in. The prefill is a
// convenience only: it reads the selection via Accessibility, and where a ⌘C would be needed (AX-unavailable) only
// when the clipboard restores perfectly — it never risks a rich/image clipboard to prefill a word the user can type.
//
// "Add & Correct" saves the entry, then pastes the corrected value back over that selection via the shared safe
// insertion path (single ⌘Z) — only once the stashed source app is confirmed frontmost, never blind. If focus
// cannot be handed back, the entry is still saved and the panel says the text was left unchanged.
@MainActor
final class CorrectionPanelController {
    private var window: NSWindow?
    private let destinations: () -> [CorrectionDestination]
    private let analyze: (VocabularyProposal, CorrectionDestination) -> VocabularyAnalysis
    private let addDictionaryWord: (String, CorrectionDestination) -> Bool
    private let addReplacement: (String, String, Bool, CorrectionDestination) -> Bool
    private let captureSelection: () async -> String?
    private var previousApp: NSRunningApplication?
    private let status = CorrectionPanelStatus()

    init(
        destinations: @escaping () -> [CorrectionDestination] = { [.global] },
        analyze: @escaping (VocabularyProposal, CorrectionDestination) -> VocabularyAnalysis,
        addDictionaryWord: @escaping (String, CorrectionDestination) -> Bool,
        addReplacement: @escaping (String, String, Bool, CorrectionDestination) -> Bool,
        captureSelection: @escaping () async -> String? = { await TextInserter.captureSelection(requirePerfectRestore: true) }
    ) {
        self.destinations = destinations
        self.analyze = analyze
        self.addDictionaryWord = addDictionaryWord
        self.addReplacement = addReplacement
        self.captureSelection = captureSelection
    }

    func present() {
        previousApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            let selection = (await captureSelection())?.trimmingCharacters(in: .whitespacesAndNewlines)
            show(prefill: selection?.isEmpty == false ? selection : nil)
        }
    }

    private var hasPasteTarget: Bool {
        guard let app = previousApp else { return false }
        return app.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    private func show(prefill: String?) {
        window?.close()
        status.message = nil
        let view = CorrectionPanelView(
            prefill: prefill ?? "",
            canCorrect: prefill != nil && hasPasteTarget,
            destinations: destinations(),
            analyze: analyze,
            status: status,
            onSave: { [weak self] result in
                guard let self else { return }
                switch self.apply(result) {
                case .saved:
                    self.window?.close()
                case .noChange:
                    self.status.refresh()
                case .failed:
                    self.status.message = Self.saveFailedMessage(for: Self.destination(of: result))
                }
            },
            onCorrect: { [weak self] result, pasteText in self?.applyAndCorrect(result, pasteText: pasteText) },
            onCancel: { [weak self] in self?.window?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Add to Vocabulary"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private enum SaveOutcome { case saved, noChange, failed }

    private func apply(_ result: CorrectionPanelView.SaveResult) -> SaveOutcome {
        if case .noChange = analyze(Self.proposal(of: result), Self.destination(of: result)).action {
            return .noChange
        }
        let saved: Bool
        switch result {
        case .dictionary(let word, let destination): saved = addDictionaryWord(word, destination)
        case .replacement(let heard, let replace, let regex, let destination):
            saved = addReplacement(heard, replace, regex, destination)
        }
        return saved ? .saved : .failed
    }

    static func saveFailedMessage(for destination: CorrectionDestination) -> String {
        switch destination.scope {
        case .global:
            return "\(Branding.appName) could not save this — a configuration file may be malformed. Open Settings ▸ Maintenance to fix it."
        case .mode:
            return "\(Branding.appName) could not save this to \(destination.title). Its mode file may be malformed. Open Settings ▸ Modes to fix it."
        }
    }

    private static func destination(of result: CorrectionPanelView.SaveResult) -> CorrectionDestination {
        switch result {
        case .dictionary(_, let d): return d
        case .replacement(_, _, _, let d): return d
        }
    }

    private static func proposal(of result: CorrectionPanelView.SaveResult) -> VocabularyProposal {
        switch result {
        case .dictionary(let word, _): return .word(word)
        case .replacement(let heard, let replace, let regex, _):
            return .replacement(heard: heard, replace: replace, regex: regex)
        }
    }

    private func applyAndCorrect(_ result: CorrectionPanelView.SaveResult, pasteText: String) {
        switch apply(result) {
        case .failed:
            status.message = Self.saveFailedMessage(for: Self.destination(of: result))
            return
        case .noChange, .saved:
            break
        }
        status.message = nil
        guard hasPasteTarget, let target = previousApp, !pasteText.isEmpty else {
            window?.close()
            return
        }
        window?.orderOut(nil)
        Task { @MainActor in
            guard await TextInserter.pasteReturning(to: target, text: pasteText) else {
                status.message = "Saved to your vocabulary. \(Branding.appName) could not return to the app, so the selected text was not changed."
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                return
            }
            window?.close()
        }
    }
}

@MainActor
final class CorrectionPanelStatus: ObservableObject {
    @Published var message: String?
    @Published private(set) var revision = 0

    func refresh() { revision += 1 }
}

struct CorrectionDestination: Hashable, Identifiable {
    enum Scope: Hashable {
        case global
        case mode(String)
    }

    let scope: Scope
    let title: String
    let menuTitle: String

    var id: Scope { scope }

    static let global = CorrectionDestination(scope: .global, title: "Global", menuTitle: "Global")

    static func mode(id: String, name: String) -> CorrectionDestination {
        CorrectionDestination(scope: .mode(id), title: name, menuTitle: name)
    }

    // Global plus the user's enabled, non-system modes. A disabled mode is excluded: a term routed there
    // would do nothing until the mode is enabled, with no hint at the panel.
    static func list(for modes: [Mode]) -> [CorrectionDestination] {
        [.global] + modes.filter { !$0.isSystem && $0.enabled }.map { .mode(id: $0.id, name: $0.name) }
    }
}

private struct CorrectionPanelView: View {
    enum SaveResult {
        case dictionary(word: String, destination: CorrectionDestination)
        case replacement(heard: String, replace: String, regex: Bool, destination: CorrectionDestination)
    }

    // The selection captured when the panel opened. "Add & Replace Selection" pastes the rule's effect
    // on *this* text, so a regex is applied to the original selection — not to the pattern field.
    let originalSelection: String
    let canCorrect: Bool
    let destinations: [CorrectionDestination]
    let analyze: (VocabularyProposal, CorrectionDestination) -> VocabularyAnalysis
    let onSave: (SaveResult) -> Void
    let onCorrect: (SaveResult, String) -> Void
    let onCancel: () -> Void
    @ObservedObject var status: CorrectionPanelStatus

    @State private var term: String
    @State private var replace: String
    @State private var regex = false
    @State private var destination: CorrectionDestination
    @FocusState private var focus: Field?

    private enum Field { case term, replace }

    init(
        prefill: String, canCorrect: Bool,
        destinations: [CorrectionDestination],
        analyze: @escaping (VocabularyProposal, CorrectionDestination) -> VocabularyAnalysis,
        status: CorrectionPanelStatus,
        onSave: @escaping (SaveResult) -> Void, onCorrect: @escaping (SaveResult, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let destinations = destinations.isEmpty ? [.global] : destinations
        self.originalSelection = prefill
        self.canCorrect = canCorrect
        self.destinations = destinations
        self.analyze = analyze
        self.status = status
        self.onSave = onSave
        self.onCorrect = onCorrect
        self.onCancel = onCancel
        _term = State(initialValue: prefill)
        _replace = State(initialValue: "")
        _destination = State(initialValue: destinations[0])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a word \(Branding.appName) should recognize, or fill in Use instead to replace a phrase \(Branding.appName) keeps hearing wrong.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(regex ? "Heard pattern" : "Word or heard phrase")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(regex ? "Regular expression" : "e.g. Kubernetes", text: $term)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .term)
                        .onSubmit(commitSave)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier(AccessibilityID.Correction.term)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(regex ? "Use instead" : "Use instead (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(regex ? "Replacement text" : "Optional correction", text: $replace)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .replace)
                        .onSubmit(commitSave)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier(AccessibilityID.Correction.useInstead)
                }
            }

            if let feedback = draft.feedback {
                VocabularyFeedbackView(feedback: feedback)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.Correction.status)
            }

            Toggle("Match heard phrase as a regular expression", isOn: $regex)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier(AccessibilityID.Correction.regexToggle)

            HStack(spacing: 10) {
                Text("Save to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if destinations.count == 1 {
                    Text(destination.title)
                        .font(.callout)
                        .foregroundStyle(.primary)
                } else {
                    Picker("", selection: $destination) {
                        ForEach(destinations) { destination in
                            Text(destination.menuTitle).tag(destination)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(AccessibilityID.Correction.destination)
                }
                Spacer()
            }

            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if regexInvalid {
                IssueText("That is not a valid regular expression.")
            }

            Text(saveDestinationText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = status.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.Correction.cancel)
                if canCorrect && hasReplacementValue {
                    Button("Add & Replace Selection") { onCorrect(buildResult(), correctionPasteText()) }.disabled(!canCorrectNow)
                        .accessibilityIdentifier(AccessibilityID.Correction.addAndReplace)
                }
                Button(draft.buttonTitle, action: commitSave)
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
                    .accessibilityIdentifier(AccessibilityID.Correction.add)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                focus = .term
            }
        }
    }

    private var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedReplace: String { replace.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var correctedValue: String {
        trimmedReplace.isEmpty ? trimmedTerm : trimmedReplace
    }

    private var regexInvalid: Bool {
        regex && !trimmedTerm.isEmpty && !RegexCache.isValidPattern(trimmedTerm)
    }

    private var canSave: Bool {
        draft.canCommit
    }

    private var hasReplacementValue: Bool { !trimmedReplace.isEmpty }

    private var canCorrectNow: Bool { draft.canApplyCorrection && hasReplacementValue && !correctedValue.isEmpty }

    private var draft: VocabularyDraftAnalysis {
        _ = status.revision
        return VocabularyDraftAnalysis(
            term: trimmedTerm, replacement: trimmedReplace, regex: regex,
            analyze: { analyze($0, destination) })
    }

    private var entryKind: String {
        (!regex && trimmedReplace.isEmpty) ? "vocabulary" : "replacements"
    }

    private var saveDestinationText: String {
        switch destination.scope {
        case .global:
            return "Saves to global \(entryKind). Nothing leaves this Mac."
        case .mode:
            return "Saves to \(destination.title) \(entryKind). Nothing leaves this Mac."
        }
    }

    // What "Add & Replace Selection" pastes over the captured selection: the replacement text, or — for a
    // regex rule — the rule applied to the original selection (not to the pattern in the heard field).
    private func correctionPasteText() -> String {
        guard regex else { return correctedValue }
        guard let re = RegexCache.regex(trimmedTerm) else { return originalSelection }
        let range = NSRange(originalSelection.startIndex..., in: originalSelection)
        return re.stringByReplacingMatches(in: originalSelection, range: range, withTemplate: trimmedReplace)
    }

    private var helpText: String {
        if regex {
            return "Regex always creates a replacement, so Use instead is required. Use captures like $1. Replacements run before any AI rewrite."
        }
        return "Leave Use instead empty to add a word. Fill it in to create an automatic replacement. Dictionary entries are hints; replacements run before any AI rewrite."
    }

    private func commitSave() {
        guard canSave else { return }
        onSave(buildResult())
    }

    private func buildResult() -> SaveResult {
        if !regex && trimmedReplace.isEmpty {
            return .dictionary(word: trimmedTerm, destination: destination)
        }
        return .replacement(heard: trimmedTerm, replace: trimmedReplace, regex: regex, destination: destination)
    }
}
