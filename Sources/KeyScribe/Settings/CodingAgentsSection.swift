import AppKit
import KeyScribeKit
import SwiftUI

struct CodingAgentRecipientSection: View {
    @ObservedObject var model: CodingAgentsSettingsModel
    let shortcut: String?
    @State private var renaming: CodingAgentsSettingsModel.Row?
    @State private var showingNameDetails = false

    var body: some View {
        Section("Conversations") {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.currentName.map { "Current recipient: \($0)" } ?? "No current recipient")
                Text(model.recipientGuidance(shortcut: shortcut))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.currentRecipient)
            if let problem = model.namesProblem {
                namesUnavailable(problem)
            } else if let reason = model.namesNotSaved {
                VStack(alignment: .leading, spacing: 2) {
                    IssueText("Names given to these conversations could not be saved, so they may change when \(Branding.appName) restarts. \(Branding.appName) keeps trying.", severity: .advisory)
                    Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.namesNotSaved)
            }
            ForEach(model.rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    PaneListRow(
                        title: row.name,
                        badges: { if row.current { PaneBadge("Current", kind: .prominent) } },
                        trailing: {
                            HStack(spacing: 12) {
                                if model.showsAgentType {
                                    Text(row.agent.capitalized).foregroundStyle(.secondary).fixedSize()
                                }
                                Text(row.state)
                                    .foregroundStyle(row.connected ? Color.secondary : Color.orange)
                                    .fixedSize()
                                Button("Rename\u{2026}") {
                                    model.clearRenameProblem()
                                    renaming = row
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .fixedSize()
                                .disabled(model.namesProblem != nil)
                                .accessibilityLabel("Rename \(row.name)")
                                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.rename)
                            }
                            .font(.caption)
                        })
                    .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 12) {
                        directory(row)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let terminal = row.terminal {
                            Text(terminal).lineLimit(1).truncationMode(.middle).help(terminal)
                                .layoutPriority(1)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(row.name)
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.conversation)
            }
        }
        .sheet(item: $renaming, onDismiss: { model.clearRenameProblem() }) { row in
            ConversationNameEditor(row: row, model: model) { renaming = nil }
        }
    }

    private func directory(_ row: CodingAgentsSettingsModel.Row) -> some View {
        CopyableValue((row.folder as NSString).abbreviatingWithTildeInPath, value: row.folder, what: "directory", of: row.name)
            .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.copyDirectory)
    }

    private func namesUnavailable(_ problem: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IssueText("Saved conversation names could not be loaded.")
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.namesProblem)
            HStack {
                Button("Try Again") { model.reloadNames() }
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.reloadNames)
                Spacer()
            }
            DisclosureSection("Details", isExpanded: $showingNameDetails) {
                Text(problem).font(.caption).textSelection(.enabled)
                Text("Restore the names file, then try again. If you remove it, your chosen names will be forgotten.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.namesFile]) }
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.showNamesFile)
            }
        }
    }
}

private struct ConversationNameEditor: View {
    let row: CodingAgentsSettingsModel.Row
    @ObservedObject var model: CodingAgentsSettingsModel
    let onDone: () -> Void
    @State private var name: String
    @State private var showingFailureDetails = false
    @FocusState private var nameFocused: Bool

    init(row: CodingAgentsSettingsModel.Row, model: CodingAgentsSettingsModel, onDone: @escaping () -> Void) {
        self.row = row
        self.model = model
        self.onDone = onDone
        _name = State(initialValue: row.name)
    }

    private var issue: String? { model.renameProblem ?? model.renameIssue(row.id, name: name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename conversation").font(.title2.bold())
            Text("Choose a short name you can say. This changes its name in \(Branding.appName); the agent keeps its own title.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                if let title = row.title, !title.isEmpty {
                    Text(title).lineLimit(2).help(title)
                }
                Text((row.folder as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle).help(row.folder)
            }
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Form {
                TextField("Name you say", text: $name)
                    .focused($nameFocused)
                    .formFieldLabel("Name you say")
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.renameName)
                    .onSubmit(commit)
                if let issue {
                    IssueText(issue).accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.renameProblem)
                } else {
                    Text(model.renameExample(row.id, name: name))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let details = model.renameDetails {
                    DisclosureSection("Technical details", isExpanded: $showingFailureDetails) {
                        Text(details).font(.caption).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: model.renameDetails == nil ? 130 : showingFailureDetails ? 260 : 190)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.renameCancel)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.renameIssue(row.id, name: name) != nil || model.namesProblem != nil)
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.renameSave)
            }
        }
        .padding(24).frame(width: 440)
        .onAppear { nameFocused = true }
        .onChange(of: name) { _, _ in model.clearRenameProblem() }
    }

    private func commit() {
        guard model.renameIssue(row.id, name: name) == nil, model.namesProblem == nil else { return }
        if model.rename(row.id, to: name) { onDone() }
    }
}
