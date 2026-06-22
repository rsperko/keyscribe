import AppKit
import KeyScribeKit
import SwiftUI

// The standalone correction surfaces (design.md §4.7): a small panel to add a dictionary term or a
// literal replacement without opening Settings. Reachable from the menu and from optional global
// shortcuts. The Heard/term field is pre-filled best-effort from the current selection — captured
// before KeyScribe activates so the synthetic ⌘C still reaches the app the user was working in.
@MainActor
final class CorrectionPanelController {
    enum Kind { case dictionary, replacement }

    private var window: NSWindow?
    private let addDictionaryWord: (String) -> Void
    private let addReplacement: (String, String) -> Void
    private let captureSelection: () async -> String?

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
        Task { @MainActor in
            let selection = (await captureSelection())?.trimmingCharacters(in: .whitespacesAndNewlines)
            show(kind, prefill: selection?.isEmpty == false ? selection : nil)
        }
    }

    private func show(_ kind: Kind, prefill: String?) {
        window?.close()
        let view = CorrectionPanelView(
            kind: kind, prefill: prefill ?? "",
            onSave: { [weak self] result in
                switch result {
                case .dictionary(let word): self?.addDictionaryWord(word)
                case .replacement(let heard, let replace): self?.addReplacement(heard, replace)
                }
                self?.window?.close()
            },
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
}

private struct CorrectionPanelView: View {
    enum SaveResult {
        case dictionary(word: String)
        case replacement(heard: String, replace: String)
    }

    let kind: CorrectionPanelController.Kind
    let onSave: (SaveResult) -> Void
    let onCancel: () -> Void

    @State private var term: String
    @State private var replace: String

    init(
        kind: CorrectionPanelController.Kind, prefill: String,
        onSave: @escaping (SaveResult) -> Void, onCancel: @escaping () -> Void
    ) {
        self.kind = kind
        self.onSave = onSave
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
                    TextField("e.g. LaunchDarkly", text: $term).textFieldStyle(.roundedBorder)
                }
            case .replacement:
                LabeledContent("When you say") {
                    TextField("e.g. my email", text: $term).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Insert") {
                    TextField("e.g. me@example.com", text: $replace).textFieldStyle(.roundedBorder)
                }
            }

            Text("Saved to your global vocabulary. Nothing leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Add", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var explanation: String {
        switch kind {
        case .dictionary:
            return "Teach KeyScribe a word so it is recognized and not changed as a misspelling."
        case .replacement:
            return "When you speak the first phrase, KeyScribe inserts the second instead."
        }
    }

    private var trimmedTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        switch kind {
        case .dictionary: return !trimmedTerm.isEmpty
        case .replacement: return !trimmedTerm.isEmpty
        }
    }

    private func save() {
        guard canSave else { return }
        switch kind {
        case .dictionary:
            onSave(.dictionary(word: trimmedTerm))
        case .replacement:
            onSave(.replacement(heard: trimmedTerm, replace: replace))
        }
    }
}
