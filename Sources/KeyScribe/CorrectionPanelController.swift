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
    enum Kind { case dictionary, replacement }

    private var window: NSWindow?
    private let addDictionaryWord: (String) -> Void
    private let addReplacement: (String, String) -> Void
    private let captureSelection: () async -> String?
    // The app that was frontmost when the panel opened — the target "Add & Correct" pastes into, since
    // the panel itself becomes key once shown.
    private var previousApp: NSRunningApplication?
    private let status = CorrectionPanelStatus()

    init(
        addDictionaryWord: @escaping (String) -> Void,
        addReplacement: @escaping (String, String) -> Void,
        captureSelection: @escaping () async -> String? = { await TextInserter.captureSelection() }
    ) {
        self.addDictionaryWord = addDictionaryWord
        self.addReplacement = addReplacement
        self.captureSelection = captureSelection
    }

    func present(_ kind: Kind) {
        previousApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            let selection = (await captureSelection())?.trimmingCharacters(in: .whitespacesAndNewlines)
            show(kind, prefill: selection?.isEmpty == false ? selection : nil)
        }
    }

    private var hasPasteTarget: Bool {
        guard let app = previousApp else { return false }
        return app.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    private func show(_ kind: Kind, prefill: String?) {
        window?.close()
        status.message = nil
        let view = CorrectionPanelView(
            kind: kind, prefill: prefill ?? "",
            canCorrect: prefill != nil && hasPasteTarget,
            status: status,
            onSave: { [weak self] result in
                self?.apply(result)
                self?.window?.close()
            },
            onCorrect: { [weak self] result in self?.applyAndCorrect(result) },
            onCancel: { [weak self] in self?.window?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = kind == .dictionary ? "Add Dictionary Entry" : "Add Replacement"
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
        case .replacement(let heard, let replace): addReplacement(heard, replace)
        }
    }

    private func applyAndCorrect(_ result: CorrectionPanelView.SaveResult) {
        apply(result)
        status.message = nil
        let pasteText = result.correctedValue
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
            // Let the reactivated field settle (and keep its selection live) before the replacing paste.
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
        case replacement(heard: String, replace: String)

        var correctedValue: String {
            switch self {
            case .dictionary(let word): return word
            case .replacement(_, let replace): return replace
            }
        }
    }

    let kind: CorrectionPanelController.Kind
    let canCorrect: Bool
    let onSave: (SaveResult) -> Void
    let onCorrect: (SaveResult) -> Void
    let onCancel: () -> Void
    @ObservedObject var status: CorrectionPanelStatus

    @State private var term: String
    @State private var replace: String
    @FocusState private var focus: Field?

    private enum Field { case term, replace }

    init(
        kind: CorrectionPanelController.Kind, prefill: String, canCorrect: Bool,
        status: CorrectionPanelStatus,
        onSave: @escaping (SaveResult) -> Void, onCorrect: @escaping (SaveResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.kind = kind
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
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch kind {
            case .dictionary:
                LabeledContent("Word") {
                    TextField("e.g. Kubernetes", text: $term).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .term)
                }
            case .replacement:
                LabeledContent("When you say") {
                    TextField("e.g. my email", text: $term).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .term)
                }
                LabeledContent("Insert") {
                    TextField("e.g. me@example.com", text: $replace).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .replace)
                }
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
                if canCorrect {
                    Button(correctTitle) { onCorrect(buildResult()) }.disabled(!canCorrectNow)
                }
                Button("Add") { onSave(buildResult()) }
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                focus = trimmedTerm.isEmpty ? .term : initialFocusWhenPrefilled
            }
        }
    }

    private var initialFocusWhenPrefilled: Field {
        kind == .replacement ? .replace : .term
    }

    private var explanation: String {
        switch kind {
        case .dictionary:
            return "Teach KeyScribe a word so it is recognized and not changed as a misspelling."
        case .replacement:
            return "When you speak the first phrase, KeyScribe inserts the second instead."
        }
    }

    private var correctTitle: String {
        kind == .dictionary ? "Add & Correct" : "Add & Insert"
    }

    private var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var correctedValue: String {
        switch kind {
        case .dictionary: return trimmedTerm
        case .replacement: return replace.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var canSave: Bool { !trimmedTerm.isEmpty }
    private var canCorrectNow: Bool { canSave && !correctedValue.isEmpty }

    private func buildResult() -> SaveResult {
        switch kind {
        case .dictionary: return .dictionary(word: trimmedTerm)
        case .replacement: return .replacement(heard: trimmedTerm, replace: replace)
        }
    }
}
