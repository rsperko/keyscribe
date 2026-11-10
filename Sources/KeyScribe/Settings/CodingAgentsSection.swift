import AppKit
import KeyScribeKit
import SwiftUI
import UniformTypeIdentifiers

struct CodingAgentRecipientSection: View {
    @ObservedObject var model: CodingAgentsSettingsModel
    let shortcut: String?
    @State private var renaming: CodingAgentsSettingsModel.Row?
    @State private var showingNameDetails = false
    @State private var showingDisconnected = false
    @State private var showingMissing = false
    @State private var choosingFolder: AgentConnectorModel?
    @State private var folderProblem: String?
    @AccessibilityFocusState private var focusedReconnect: String?

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
            if let reason = model.exclusionsNotSaved {
                VStack(alignment: .leading, spacing: 6) {
                    IssueText("Disconnected for now. Couldn\u{2019}t save this choice for the next launch.")
                    Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Try Again") { model.onRetrySavingExclusions?() }
                        .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.tryAgain)
                }
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.exclusionsProblem)
            }
            if model.rows.isEmpty {
                Text(model.emptyState).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.rows, id: \.key) { row in
                conversationRow(row)
            }
            if !model.disconnectedRows.isEmpty {
                DisclosureSection("Disconnected conversations", isExpanded: $showingDisconnected, headerID: AccessibilityID.Mode.CodingAgents.disconnected) {
                    Text("These conversations stay disconnected when reopened. New conversations connect normally.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.disconnectedRows, id: \.key) { row in
                        disconnectedRow(row)
                    }
                }
            }
            DisclosureSection("Conversation missing?", isExpanded: $showingMissing, hasError: folderProblem != nil, headerID: AccessibilityID.Mode.CodingAgents.missing) {
                missingHelp
            }
        }
        .sheet(item: $renaming, onDismiss: { model.clearRenameProblem() }) { row in
            ConversationNameEditor(row: row, model: model) { renaming = nil }
        }
        .sheet(item: $model.consent) { request in
            ConnectorConsentSheet(model: model, request: request)
        }
        .fileImporter(
            isPresented: Binding(get: { choosingFolder != nil }, set: { if !$0 { choosingFolder = nil } }),
            allowedContentTypes: [.folder]
        ) { result in
            guard let connector = choosingFolder, case .success(let url) = result else { return }
            choosingFolder = nil
            folderProblem = model.choose(folder: url, for: connector)
        }
    }

    private func conversationRow(_ row: CodingAgentsSettingsModel.Row) -> some View {
        let action = model.action(for: row)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 12) {
                conversationHeading(row)
                HStack(spacing: 8) { rowButtons(row, action: action) }
                    .fixedSize()
            }
            HStack(spacing: 8) {
                if model.showsAgentType {
                    Text(model.connector(for: row)?.kind.displayName ?? row.agent).fixedSize()
                }
                directory(row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let location = row.location {
                    Text(location).lineLimit(1).truncationMode(.middle).help(location)
                        .layoutPriority(1)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let others = model.alsoAnswers(row) {
                Text(others).font(.caption).foregroundStyle(.secondary)
            }
            if let trouble = CodingAgentsSettingsModel.placeTrouble(row) {
                Text(trouble).font(.caption).foregroundStyle(.secondary)
            }
            if let context = model.recognitionContext(for: row) {
                Text(context).font(.caption).foregroundStyle(.secondary)
            }
            if case .recover(let reload) = action {
                recovery(row, reload: reload)
            }
            if row.olderConnector {
                Text(olderConnectorNote(row)).font(.caption).foregroundStyle(.secondary)
            }
            if let readAloud = row.readAloud {
                HStack(spacing: 8) {
                    Text(readAloud.note).font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelReadAloud(row) }
                        .buttonStyle(.link).controlSize(.small).font(.caption)
                        .accessibilityLabel("Don\u{2019}t read \(row.name)\u{2019}s reply aloud")
                        .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.cancelReadAloud)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            [
                row.name, row.state, row.folder, row.location, model.alsoAnswers(row), CodingAgentsSettingsModel.placeTrouble(row),
                model.recognitionContext(for: row), row.readAloud?.note,
            ]
                .compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.conversation)
    }

    private func conversationHeading(_ row: CodingAgentsSettingsModel.Row) -> some View {
        let title = PaneListRow(title: row.name, badges: {
            if row.current { PaneBadge("Current", kind: .prominent).fixedSize() }
        })
        let state = Text(row.state).font(.caption)
            .foregroundStyle(row.connected ? Color.secondary : Color.orange).fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                title
                state.padding(.vertical, 2)
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 2) {
                title
                state
            }
        }
        .lineLimit(2).truncationMode(.middle).help(row.name)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func rowButtons(_ row: CodingAgentsSettingsModel.Row, action: CodingAgentsSettingsModel.RowAction) -> some View {
        if action == .connect {
            Button("Connect\u{2026}") { model.connect(row) }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
                .accessibilityLabel("Connect \(row.name)")
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.connect)
        }
        if row.identified {
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
        if action == .connected {
            Button("Disconnect") {
                focusedReconnect = row.id
                showingDisconnected = true
                model.disconnect(row)
            }
            .buttonStyle(.bordered).controlSize(.small).fixedSize()
            .disabled(model.namesProblem != nil)
            .accessibilityLabel("Disconnect \(row.name)")
            .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.disconnect)
        }
    }

    private func recovery(_ row: CodingAgentsSettingsModel.Row, reload: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reload {
                Text("Connector installed. Run \(reload) in this conversation.").font(.caption)
                CopyableValue(reload, value: reload, what: "command", of: row.name)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.reloadCommand)
            } else {
                Text("Connector installed, but this conversation hasn\u{2019}t connected yet.").font(.caption)
            }
            HStack {
                if row.identified {
                    Button("Show Conversation") { model.onShow?(row.id) }
                        .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.showConversation)
                }
                Button("Try Again") { model.onCheckAgain?() }
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.checkAgain)
            }
            .controlSize(.small)
        }
        .padding(.top, 2)
        .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.recovery)
    }

    private func olderConnectorNote(_ row: CodingAgentsSettingsModel.Row) -> String {
        let reload = model.connector(for: row)?.kind.reloadCommand.map { "Run \($0) in it when convenient." } ?? "Restart it when convenient."
        return "Still using the previous connector, which keeps working. \(reload)"
    }

    private func disconnectedRow(_ row: CodingAgentsSettingsModel.Row) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1)
                Text((row.folder as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Reconnect") { model.reconnect(row) }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.namesProblem != nil)
                .accessibilityLabel("Reconnect \(row.name)")
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.reconnect)
                .accessibilityFocused($focusedReconnect, equals: row.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name), disconnected, \(row.folder)")
    }

    private var missingHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Branding.appName) finds conversations from the agents running on this Mac and the folders their connectors are installed in. It can miss agents started through unusual wrappers or hosted inside other programs.")
                .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { missingActions }.fixedSize()
                VStack(alignment: .leading, spacing: 8) { missingActions }
            }
            .controlSize(.small)
            Text("Choosing a folder tells \(Branding.appName) where to install. It does not show which conversations use that folder.")
                .font(.caption).foregroundStyle(.secondary)
            if let folderProblem {
                IssueText(folderProblem)
            }
        }
    }

    private var missingActions: some View {
        Group {
            Button("Try Again") { model.onCheckAgain?() }
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.checkAgain)
            ForEach(model.connectors) { connector in
                Button("Choose \(connector.kind.displayName) Setup Folder\u{2026}") { choosingFolder = connector }
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.chooseSetupFolder)
            }
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
                Text("Until it can be read, conversations stay disconnected. Restore the names file, then try again. If you remove it, your chosen names and the conversations you disconnected will be forgotten.")
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
            VStack(alignment: .leading, spacing: 4) {
                if let note = model.defaultNameNote(row) {
                    Text(note).accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.defaultName)
                }
                if let note = CodingAgentsSettingsModel.placeNote(row) {
                    Text(note)
                }
                if let trouble = CodingAgentsSettingsModel.placeTrouble(row) {
                    Text(trouble)
                }
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if row.renamed {
                    Button("Use Default Name") {
                        if model.useDefaultName(row.id) { onDone() }
                    }
                    .disabled(model.namesProblem != nil)
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.useDefaultName)
                }
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
