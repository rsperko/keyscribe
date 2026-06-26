import AppKit
import KeyScribeKit
import SwiftUI

// The standalone correction surfaces (design.md §4.7): a small panel to add a dictionary term or a
// literal replacement without opening Settings. Reachable from the menu and from optional global
// shortcuts. The Heard/term field is pre-filled best-effort from the current selection — captured
// before KeyScribe activates so the synthetic ⌘C still reaches the app the user was working in.
//
// "Add & Correct" saves the entry and then pastes the corrected value back over that selection in the
// source app. The selection only ever drives prefill; the paste reuses the shared safe insertion path
// (single ⌘Z undo) and is only ever posted once the stashed source app is confirmed frontmost — never
// blind. If focus cannot be handed back, the entry is still saved and the panel says the text was left
// unchanged.
@MainActor
final class CorrectionPanelController {
    private var window: NSWindow?
    private let addDictionaryWord: (String) -> Void
    private let addReplacement: (String, String, Bool) -> Void
    private let captureSelection: () async -> String?
    private var previousApp: NSRunningApplication?
    private let status = CorrectionPanelStatus()

    init(
        addDictionaryWord: @escaping (String) -> Void,
        addReplacement: @escaping (String, String, Bool) -> Void,
        captureSelection: @escaping () async -> String? = { await TextInserter.captureSelection() }
    ) {
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
            status: status,
            onSave: { [weak self] result in
                self?.apply(result)
                self?.window?.close()
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

    private func apply(_ result: CorrectionPanelView.SaveResult) {
        switch result {
        case .dictionary(let word): addDictionaryWord(word)
        case .replacement(let heard, let replace, let regex): addReplacement(heard, replace, regex)
        }
    }

    private func applyAndCorrect(_ result: CorrectionPanelView.SaveResult, pasteText: String) {
        apply(result)
        status.message = nil
        guard hasPasteTarget, let target = previousApp, !pasteText.isEmpty else {
            window?.close()
            return
        }
        window?.orderOut(nil)
        Task { @MainActor in
            target.activate()
            guard await waitUntilFrontmost(target) else {
                status.message = "Saved to your vocabulary. KeyScribe could not return to the app, so the selected text was not changed."
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            await TextInserter.insertViaPaste(pasteText)
            window?.close()
        }
    }

    // Poll for the source app to actually become frontmost before we paste. activate() is asynchronous,
    // so a single check races it; if it never lands we bail rather than paste into the wrong target.
    private func waitUntilFrontmost(_ target: NSRunningApplication, timeoutMs: Int = 600, stepMs: Int = 50) async -> Bool {
        var waited = 0
        while waited < timeoutMs {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { return true }
            try? await Task.sleep(for: .milliseconds(stepMs))
            waited += stepMs
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }
}

@MainActor
final class CorrectionPanelStatus: ObservableObject {
    @Published var message: String?
}

private struct CorrectionPanelView: View {
    enum SaveResult {
        case dictionary(word: String)
        case replacement(heard: String, replace: String, regex: Bool)
    }

    // The selection captured when the panel opened. "Add & Replace Selection" pastes the rule's effect
    // on *this* text, so a regex is applied to the original selection — not to the pattern field.
    let originalSelection: String
    let canCorrect: Bool
    let onSave: (SaveResult) -> Void
    let onCorrect: (SaveResult, String) -> Void
    let onCancel: () -> Void
    @ObservedObject var status: CorrectionPanelStatus

    @State private var term: String
    @State private var replace: String
    @State private var regex = false
    @FocusState private var focus: Field?

    private enum Field { case term, replace }

    init(
        prefill: String, canCorrect: Bool,
        status: CorrectionPanelStatus,
        onSave: @escaping (SaveResult) -> Void, onCorrect: @escaping (SaveResult, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.originalSelection = prefill
        self.canCorrect = canCorrect
        self.status = status
        self.onSave = onSave
        self.onCorrect = onCorrect
        self.onCancel = onCancel
        _term = State(initialValue: prefill)
        _replace = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a word KeyScribe should recognize, or fill in Use instead to replace a phrase KeyScribe keeps hearing wrong.")
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
                }
            }

            Toggle("Match heard phrase as a regular expression", isOn: $regex)
                .toggleStyle(.checkbox)

            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if regexInvalid {
                Label("That is not a valid regular expression.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Saved to your global vocabulary. Nothing leaves this Mac.")
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
                if canCorrect && hasReplacementValue {
                    Button("Add & Replace Selection") { onCorrect(buildResult(), correctionPasteText()) }.disabled(!canCorrectNow)
                }
                Button("Add", action: commitSave)
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
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
        regex && !trimmedTerm.isEmpty && RegexCache.regex(trimmedTerm) == nil
    }

    private var canSave: Bool {
        !trimmedTerm.isEmpty && (!regex || !trimmedReplace.isEmpty) && !regexInvalid
    }

    private var hasReplacementValue: Bool { !trimmedReplace.isEmpty }

    private var canCorrectNow: Bool { canSave && hasReplacementValue && !correctedValue.isEmpty }

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
            return .dictionary(word: trimmedTerm)
        }
        return .replacement(heard: trimmedTerm, replace: trimmedReplace, regex: regex)
    }
}
