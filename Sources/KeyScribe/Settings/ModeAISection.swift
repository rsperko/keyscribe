import AppKit
import SwiftUI
import KeyScribeKit

struct ModeAISection: View {
    let mode: Mode
    let connections: [Connection]
    let fragmentIds: [String]
    let fragmentNames: [String: String]
    let onUpdate: (Mode) -> Void
    let onAddFragmentFile: (String) -> String?
    let onLoadFragmentBody: (String) -> String
    let onSaveFragmentBody: (String, String) -> Void
    let onCloseFragment: (String, String) -> Void
    let onRevealFragment: (String) -> Void
    @State private var newFragmentName = ""
    @State private var editingFragment: String?
    @State private var creatingFragment = false

    var body: some View {
        Section("Improve with AI") {
            if connections.isEmpty {
                if let aiServiceIssueText {
                    Label(aiServiceIssueText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("Add an AI service in Settings before a mode can rewrite the transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if let aiServiceIssueText {
                    Label(aiServiceIssueText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                SettingRow(
                    title: "AI service",
                    result: aiServiceLabel,
                    help: "When set, the transcript is sent to this AI service to be rewritten before it is inserted. Only an explicit AI service can run a rewrite; if it fails, the transcript is inserted without rewriting — your words are never lost.")
                {
                    Picker("", selection: rewriteSelection) {
                        Text("No cloud rewrite").tag("")
                        ForEach(connections) { connection in
                            Text(connection.name).tag(connection.id)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                if mode.aiRewrite != nil {
                    PromptEditor(
                        title: "Writing instruction",
                        placeholder: "Describe how the AI should rewrite your dictation\u{2026}",
                        text: mode.aiRewrite?.prompt ?? ""
                    ) { value in
                        updateRewrite { $0.prompt = value }
                    }
                    reusableInstructions
                }
            }
        }
    }

    @ViewBuilder private var reusableInstructions: some View {
        let attached = mode.aiRewrite?.fragments ?? []
        if attached.isEmpty {
            addInstructionMenu
            Text("Reusable writing instructions are saved snippets appended to this mode's prompt and shared across modes \u{2014} a \u{201C}my voice\u{201D} style guide, a standard sign-off, a glossary of names to spell right, or tone rules like \u{201C}keep it terse.\u{201D} Add one to reuse it across modes.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Reusable writing instructions")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(attached, id: \.self) { id in
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    Text(fragmentName(id)).font(.callout)
                    Spacer()
                    Button("Edit") { editingFragment = id }
                        .buttonStyle(.borderless)
                        .popover(isPresented: Binding(
                            get: { editingFragment == id },
                            set: { if !$0 { closeFragmentEditor(id) } })) {
                            fragmentEditor(id)
                        }
                    Button("Remove", role: .destructive) { removeFragment(id) }
                        .buttonStyle(.borderless)
                }
            }
            .onMove(perform: moveFragment)
            addInstructionMenu
            Text("Each is appended after the writing instruction, in order. Instructions are shared, so editing one changes it for every mode that uses it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var addInstructionMenu: some View {
        Menu {
            if !unusedFragmentIds.isEmpty {
                ForEach(unusedFragmentIds, id: \.self) { id in
                    Button(fragmentName(id)) { addFragment(id) }
                }
                Divider()
            }
            Button { creatingFragment = true } label: {
                Label("New instruction…", systemImage: "plus")
            }
        } label: {
            Label("Add instruction", systemImage: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .alert("New reusable instruction", isPresented: $creatingFragment) {
            TextField("Name, e.g. Email style", text: $newFragmentName)
            Button("Create", action: commitNewFragment)
            Button("Cancel", role: .cancel) { newFragmentName = "" }
        } message: {
            Text("Creates a reusable instruction you can edit here and attach to any mode.")
        }
    }

    @ViewBuilder private func fragmentEditor(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(fragmentName(id)).font(.headline)
            Label("Shared — editing this changes it for every mode that uses it.",
                  systemImage: "person.2")
                .font(.caption).foregroundStyle(.secondary)
            PromptEditor(
                title: fragmentName(id),
                placeholder: "Describe the reusable instruction\u{2026}",
                text: onLoadFragmentBody(id),
                commitsOnChange: true
            ) { body in
                onSaveFragmentBody(id, body)
            }
            HStack {
                Button { onRevealFragment(id) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.link).font(.caption)
                Spacer()
                Button("Done") { closeFragmentEditor(id) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func fragmentName(_ id: String) -> String {
        let name = fragmentNames[id]
        return (name?.isEmpty == false) ? name! : id
    }

    private var aiServiceLabel: String {
        guard let id = mode.aiRewrite?.connection,
              !id.isEmpty else {
            if mode.aiRewrite != nil { return "Choose an AI service" }
            return "No cloud rewrite"
        }
        guard let name = connections.first(where: { $0.id == id })?.name else { return "Missing AI service" }
        return name
    }

    private var aiServiceIssueText: String? {
        guard mode.enabled, let rewrite = mode.aiRewrite else { return nil }
        if rewrite.connection.isEmpty { return "Choose an AI service for this enabled mode." }
        if !connections.contains(where: { $0.id == rewrite.connection }) {
            return "The selected AI service no longer exists."
        }
        return nil
    }

    private var unusedFragmentIds: [String] {
        let used = Set(mode.aiRewrite?.fragments ?? [])
        return fragmentIds.filter { !used.contains($0) }
    }

    private func commitNewFragment() {
        let name = newFragmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFragmentName = ""
        guard !name.isEmpty, let id = onAddFragmentFile(name) else { return }
        addFragment(id)
        editingFragment = id
    }

    private func closeFragmentEditor(_ id: String) {
        guard editingFragment == id else { return }
        let modeId = mode.id
        editingFragment = nil
        // Tearing the popover down flushes the editor's pending edit via its onDisappear commit; let
        // that land before deciding whether the instruction is empty and should be discarded.
        Task { @MainActor in onCloseFragment(id, modeId) }
    }

    private func addFragment(_ id: String) {
        guard var rewrite = mode.aiRewrite, !rewrite.fragments.contains(id) else { return }
        rewrite.fragments.append(id)
        var updated = mode
        updated.aiRewrite = rewrite
        onUpdate(updated)
    }

    private func removeFragment(_ fragment: String) {
        guard var rewrite = mode.aiRewrite else { return }
        rewrite.fragments.removeAll { $0 == fragment }
        var updated = mode
        updated.aiRewrite = rewrite
        onUpdate(updated)
    }

    private func moveFragment(from source: IndexSet, to destination: Int) {
        guard var rewrite = mode.aiRewrite else { return }
        rewrite.fragments.move(fromOffsets: source, toOffset: destination)
        var updated = mode
        updated.aiRewrite = rewrite
        onUpdate(updated)
    }

    private var rewriteSelection: Binding<String> {
        Binding(
            get: { mode.aiRewrite?.connection ?? "" },
            set: { id in
                if id.isEmpty {
                    disableRewrite()
                } else if mode.aiRewrite == nil {
                    var updated = mode
                    updated.aiRewrite = .init(
                        connection: id,
                        prompt: "Clean up grammar and punctuation. Keep my meaning and wording.")
                    onUpdate(updated)
                } else {
                    updateRewrite { $0.connection = id }
                }
            })
    }

    private func disableRewrite() {
        var updated = mode
        updated.aiRewrite = nil
        onUpdate(updated)
    }

    private func updateRewrite(_ update: (inout Mode.AIRewrite) -> Void) {
        guard var rewrite = mode.aiRewrite else { return }
        update(&rewrite)
        var updated = mode
        updated.aiRewrite = rewrite
        onUpdate(updated)
    }
}
