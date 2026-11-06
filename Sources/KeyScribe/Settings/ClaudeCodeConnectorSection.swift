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
            if let problem = model.namesProblem { namesUnavailable(problem) }
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

struct ClaudeCodeConnectorSection: View {
    @ObservedObject var model: CodingAgentsSettingsModel
    @State private var confirmingRemove = false

    var body: some View {
        Section("Claude Code") {
            SettingRow(
                title: "Connector",
                result: statusText,
                help: "\(Branding.appName) reaches Claude Code through a small plugin installed for your user account. Installed means the plugin is in place; each session then connects on its own.",
                combinesAccessibilityChildren: false)
            {
                primaryAction
            }
            .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.connectorStatus)
            issue
            if model.showsRemovalWarning {
                IssueText(Self.stillConnected(model.connectedCount), severity: .advisory)
            }
            if isInstalled {
                Text(summary).font(.callout)
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.summary)
                if model.rows.contains(where: { !$0.connected }) || model.needsReload {
                    Text("Already running Claude Code? Run /reload-plugins once in each open session. New sessions connect on their own once you trust their folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Remove Connector\u{2026}", role: .destructive) { confirmingRemove = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .disabled(model.operation != nil)
                        .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.remove)
                }
            }
        }
        .task { await model.refresh() }
        .confirmationDialog("Remove the Claude Code connector?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await model.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New Claude Code sessions will not connect. Sessions already open keep receiving what you say until you run /reload-plugins in each one or restart it.")
        }
    }

    static func stillConnected(_ count: Int) -> String {
        count == 1
            ? "1 open session is still connected and keeps receiving what you say until you run /reload-plugins in it or restart it."
            : "\(count) open sessions are still connected and keep receiving what you say until you run /reload-plugins in each one or restart them."
    }

    private var isInstalled: Bool {
        switch model.connector {
        case .status(.ready), .status(.outdated), .status(.disabled): true
        default: false
        }
    }

    private var summary: String {
        switch (model.rows.count, model.connectedCount) {
        case (0, _): "No Claude Code sessions are running."
        case (let total, let connected): "\(connected) of \(total) \(total == 1 ? "conversation" : "conversations") connected"
        }
    }

    private var statusText: String {
        if let operation = model.operation { return operation }
        return switch model.connector {
        case .checking: "Checking…"
        case .claudeNotFound: "Claude Code not found"
        case .failed: "Something went wrong"
        case .status(.ready): "Installed"
        case .status(.notInstalled): "Not installed"
        case .status(.outdated): "Update available"
        case .status(.disabled): "Turned off in Claude Code"
        case .status(.unknown): "Unknown"
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if model.operation != nil {
            EmptyView()
        } else {
            installOrUpdate
        }
    }

    @ViewBuilder private var installOrUpdate: some View {
        switch model.connector {
        case .status(.notInstalled), .failed:
            Button("Install") { Task { await model.install() } }
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.install)
        case .status(.outdated):
            Button("Update") { Task { await model.update() } }
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.update)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var issue: some View {
        switch model.connector {
        case .claudeNotFound:
            IssueText("Install Claude Code, then come back here. \(Branding.appName) looks for the claude command on your PATH and in the usual install folders.", severity: .advisory)
        case .failed(let message):
            IssueText(message.isEmpty ? "Claude Code did not say why." : message)
        case .status(.disabled):
            IssueText("Turn the plugin back on with /plugin in Claude Code.", severity: .advisory)
        case .status(.unknown):
            IssueText("Claude Code's plugin list could not be read.", severity: .advisory)
        default:
            EmptyView()
        }
    }

}
