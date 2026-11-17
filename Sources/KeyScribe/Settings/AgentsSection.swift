import AppKit
import KeyScribeKit
import SwiftUI

struct AgentConversationList: View {
    @ObservedObject var model: AgentsSettingsModel
    let onDone: () -> Void
    @State private var query = ""
    @State private var showingUnavailable = false
    @State private var showingMissing = false
    @State private var showingNameDetails = false
    @State private var renaming: AgentsSettingsModel.Row?
    @State private var inspecting: AgentsSettingsModel.Row?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let groups = model.conversationGroups(matching: query)
        let unavailable = groups.notConnected + groups.disconnected
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Conversations").font(.title2.bold())
                Text("Manage conversation names and connections. No instructions are sent.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                problems
                if let filter = model.listFilter {
                    HStack(spacing: 8) {
                        Text("Showing \(filter.title).").font(.callout)
                            .accessibilityIdentifier(AccessibilityID.Mode.Agents.listFilter)
                        Spacer(minLength: 8)
                        Button("Show All") { model.showAllConversations() }
                            .buttonStyle(.link)
                            .accessibilityIdentifier(AccessibilityID.Mode.Agents.showAllConversations)
                    }
                }
                TextField("Search conversations", text: $query, prompt: Text("Search conversations"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .focused($searchFocused)
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.search)
            }
            .padding([.horizontal, .top], 20).padding(.bottom, 10)
            ScrollViewReader { scroll in
                List {
                    Section {
                        ForEach(groups.connected, id: \.key) { row in availableRow(row) }
                        if groups.connected.isEmpty {
                            Text(query.isEmpty ? model.emptyState : "No conversations match \u{201C}\(query)\u{201D}.")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        PaneListSectionHeader("Conversations")
                    }
                    if !unavailable.isEmpty {
                        let open = showingUnavailable || !query.isEmpty || model.listFilter != nil
                        Section {
                            if open { ForEach(unavailable, id: \.key) { row in unavailableRow(row) } }
                        } header: {
                            DisclosureSection(
                                headerOnly: Binding(get: { open }, set: { showingUnavailable = $0 }),
                                headerID: AccessibilityID.Mode.Agents.unavailableGroup
                            ) {
                                PaneListSectionHeader("Not available (\(unavailable.count))")
                            }
                        }
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.conversationList)
                .onChange(of: model.revealedKey, initial: true) { _, key in
                    guard let key else { return }
                    model.reveal([])
                    query = ""
                    showingUnavailable = true
                    DispatchQueue.main.async { scroll.scrollTo(key, anchor: .center) }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button("Check Again", systemImage: "arrow.clockwise") { model.onCheckAgain?() }
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.checkAgain)
                Button("Missing one?") { showingMissing = true }
                    .buttonStyle(.link)
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.missing)
                    .popover(isPresented: $showingMissing, arrowEdge: .top) { missingHelp.padding(16).frame(width: 340) }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.conversationsDone)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 520, height: 560)
        .sheet(item: $renaming, onDismiss: { model.clearRenameProblem() }) { row in
            ConversationNameEditor(row: row, model: model) { renaming = nil }
        }
        .sheet(item: $inspecting) { row in
            AgentConversationDetail(model: model, rowKey: row.key, fallback: row) { inspecting = nil }
        }
        .background { ConnectorConsentPresenter(model: model) }
    }

    private func availableRow(_ row: AgentsSettingsModel.Row) -> some View {
        HStack(spacing: 8) {
            rowLabel(row)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(row))
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.row(row.id))
            Spacer(minLength: 8)
            actions(row)
        }
        .padding(.vertical, 3)
        .help(row.name)
        .id(row.key)
    }

    private func unavailableRow(_ row: AgentsSettingsModel.Row) -> some View {
        let action = model.action(for: row)
        let disconnected = model.disconnectedRows.contains { $0.key == row.key }
        return HStack(spacing: 8) {
            rowLabel(row)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(row))
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.row(row.id))
            Spacer(minLength: 8)
            if disconnected {
                Button("Reconnect") { model.reconnect(row) }
                    .disabled(model.namesProblem != nil)
                    .accessibilityLabel("Reconnect \(row.name)")
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.reconnect)
            } else if action == .connect {
                Button("Connect\u{2026}") { model.connect(row) }
                    .accessibilityLabel("Connect \(row.name)")
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.connect)
            } else if case .recover = action {
                Button("How to Connect\u{2026}") { inspecting = row }
                    .accessibilityLabel("How to connect \(row.name)")
            }
            actions(row)
        }
        .padding(.vertical, 3)
        .help(row.name)
        .id(row.key)
    }

    private func rowLabel(_ row: AgentsSettingsModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 0) {
                Text(context(row)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(" \u{00B7} ").foregroundStyle(.secondary)
                Text(row.state)
                    .fontWeight(row.needsYou ? .semibold : .regular)
                    .foregroundStyle(row.needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .font(.callout)
        }
    }

    private func actions(_ row: AgentsSettingsModel.Row) -> some View {
        Menu {
            if row.identified {
                Button("Rename\u{2026}") {
                    model.clearRenameProblem()
                    renaming = row
                }
                .disabled(model.namesProblem != nil)
            }
            if row.identified, row.connected {
                Button("Show Conversation") { model.onShow?(row.id) }
            }
            Button("Details\u{2026}") { inspecting = row }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More for \(row.name)")
        .accessibilityLabel("More for \(row.name)")
        .accessibilityIdentifier(AccessibilityID.Mode.Agents.rowActions(row.id))
    }

    private func spoken(_ row: AgentsSettingsModel.Row) -> String {
        [row.name, context(row), row.state].joined(separator: ", ")
    }

    private func context(_ row: AgentsSettingsModel.Row) -> String {
        let project = (row.folder as NSString).lastPathComponent
        return [model.agentName(row), project.isEmpty ? nil : project, model.configurationFolder(of: row)].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder private var problems: some View {
        if let problem = model.namesProblem {
            VStack(alignment: .leading, spacing: 8) {
                IssueText("Saved conversation names could not be loaded.")
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.namesProblem)
                HStack {
                    Button("Try Again") { model.reloadNames() }
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.reloadNames)
                    Spacer()
                }
                DisclosureSection("Details", isExpanded: $showingNameDetails) {
                    Text(problem).font(.caption).textSelection(.enabled)
                    Text("Until it can be read, conversations stay disconnected. Restore the names file, then try again. If you remove it, your chosen names and the conversations you disconnected will be forgotten.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.namesFile]) }
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.showNamesFile)
                }
            }
        }
    }

    private var missingHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Branding.appName) finds conversations from the agents running on this Mac and the configuration folders their connectors are installed in. It can miss agents started through unusual wrappers or hosted inside other programs.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("If an agent loads its configuration from another folder, add that folder under Connections, in that agent\u{2019}s row.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AgentSavedChoicesProblems: View {
    @ObservedObject var model: AgentsSettingsModel

    var body: some View {
        if model.namesProblem != nil {
            IssueText("Saved conversation names could not be loaded. Manage conversations for details.")
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.namesProblem)
        } else if let reason = model.namesNotSaved {
            VStack(alignment: .leading, spacing: 2) {
                IssueText("Names given to these conversations could not be saved, so they may change when \(Branding.appName) restarts. \(Branding.appName) keeps trying.", severity: .advisory)
                Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Mode.Agents.namesNotSaved)
        }
        if let reason = model.exclusionsNotSaved {
            VStack(alignment: .leading, spacing: 6) {
                IssueText("Disconnected for now. Couldn\u{2019}t save this choice for the next launch.")
                Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Try Again") { model.onRetrySavingExclusions?() }
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.tryAgain)
            }
            .accessibilityIdentifier(AccessibilityID.Mode.Agents.exclusionsProblem)
        }
    }
}

private struct AgentConversationDetail: View {
    @ObservedObject var model: AgentsSettingsModel
    let rowKey: String
    let fallback: AgentsSettingsModel.Row
    let onDone: () -> Void
    @State private var showingDetails = true

    private var row: AgentsSettingsModel.Row {
        (model.rows + model.disconnectedRows).first { $0.key == rowKey } ?? fallback
    }

    private var disconnected: Bool { model.disconnectedRows.contains { $0.key == row.key } }

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider()
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.detailsDone)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 480, height: 520)
        .accessibilityIdentifier(AccessibilityID.Mode.Agents.conversationDetail)
    }

    private var form: some View {
        let action = model.action(for: row)
        return Form {
            Section {
                PaneDetailHeader(
                    systemImage: "terminal", title: row.name,
                    subtitle: [model.agentName(row), row.state].joined(separator: " \u{00B7} "),
                    badges: { EmptyView() })
                showButton(action)
                if let readAloud = row.readAloud {
                    HStack(spacing: 8) {
                        Text(readAloud.note).font(.callout)
                        Button("Cancel") { model.cancelReadAloud(row) }
                            .buttonStyle(.link)
                            .accessibilityLabel("Don\u{2019}t report \(row.name)\u{2019}s reply")
                            .accessibilityIdentifier(AccessibilityID.Mode.Agents.cancelReadAloud)
                    }
                }
                if let trouble = AgentsSettingsModel.placeTrouble(row) {
                    IssueText(trouble, severity: .advisory)
                }
            }
            primary(action)
            Section {
                DisclosureSection(
                    "Location and details", isExpanded: $showingDetails,
                    headerID: AccessibilityID.Mode.Agents.conversationDetails
                ) {
                    details
                }
            }
            footer(action)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func primary(_ action: AgentsSettingsModel.RowAction) -> some View {
        if disconnected {
            Section {
                Text("Disconnected. It stays disconnected when reopened; new conversations connect normally.")
                    .foregroundStyle(.secondary)
            }
        } else if let example = model.example(for: row) {
            Section("Say") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\u{201C}\(example.said)\u{201D}")
                    Text(example.effect).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.example)
            }
        } else {
            switch action {
            case .connect:
                Section {
                    HStack {
                        Text("Not connected. Connect it to send it instructions.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Connect\u{2026}") { model.connect(row) }
                            .accessibilityLabel("Connect \(row.name)")
                            .accessibilityIdentifier(AccessibilityID.Mode.Agents.connect)
                    }
                }
            case .recover(let reload):
                Section { recovery(reload: reload) }
            case .connected, .unknown:
                if !row.connected {
                    Section {
                        Text("Not connected. Instructions can\u{2019}t reach it right now.").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func recovery(reload: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reload {
                Text("Connector installed. Run \(reload) in this conversation.")
                CopyableValue(reload, value: reload, what: "command", of: row.name)
                    .font(.callout.monospaced())
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.reloadCommand)
            } else {
                Text("Connector installed, but this conversation hasn\u{2019}t connected yet.")
            }
            Button("Try Again") { model.onCheckAgain?() }
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.checkAgain)
        }
        .accessibilityIdentifier(AccessibilityID.Mode.Agents.recovery)
    }

    @ViewBuilder private func showButton(_ action: AgentsSettingsModel.RowAction) -> some View {
        if row.identified, row.connected || action != .connect {
            Button("Show Conversation") { model.onShow?(row.id) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Show \(row.name)")
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.showConversation)
        }
    }

    @ViewBuilder private func footer(_ action: AgentsSettingsModel.RowAction) -> some View {
        if disconnected || action == .connected {
            Section {
                HStack(spacing: 8) {
                    Spacer()
                    connectionAction(action)
                }
            }
        }
    }

    @ViewBuilder private func connectionAction(_ action: AgentsSettingsModel.RowAction) -> some View {
        if disconnected {
            Button("Reconnect") { model.reconnect(row) }
                .disabled(model.namesProblem != nil)
                .accessibilityLabel("Reconnect \(row.name)")
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.reconnect)
        } else if action == .connected {
            Button("Disconnect") { model.disconnect(row) }
            .disabled(model.namesProblem != nil)
            .accessibilityLabel("Disconnect \(row.name)")
            .accessibilityIdentifier(AccessibilityID.Mode.Agents.disconnect)
        }
    }

    @ViewBuilder private var details: some View {
        LabeledContent("Project folder") {
            CopyableValue((row.folder as NSString).abbreviatingWithTildeInPath, value: row.folder, what: "directory", of: row.name)
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.copyDirectory)
        }
        if let location = row.location {
            LabeledContent("Runs in", value: location)
        }
        if let setup = row.setup {
            LabeledContent("Configuration folder") {
                CopyableValue((setup as NSString).abbreviatingWithTildeInPath, value: setup, what: "configuration folder", of: row.name)
            }
        }
        if let title = row.title, !title.isEmpty, title != row.name {
            LabeledContent("Title", value: title)
        }
        if let context = model.recognitionContext(for: row) {
            Text(context).font(.caption).foregroundStyle(.secondary)
        }
        if let others = model.alsoAnswers(row) {
            Text(others).font(.caption).foregroundStyle(.secondary)
        }
        if let note = AgentsSettingsModel.placeNote(row) {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        if row.olderConnector {
            Text("Uses the previous connector, which keeps working. Connections lists how to update it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ConversationNameEditor: View {
    let row: AgentsSettingsModel.Row
    @ObservedObject var model: AgentsSettingsModel
    let onDone: () -> Void
    @State private var name: String
    @State private var showingFailureDetails = false
    @FocusState private var nameFocused: Bool

    init(row: AgentsSettingsModel.Row, model: AgentsSettingsModel, onDone: @escaping () -> Void) {
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
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.renameName)
                    .onSubmit(commit)
                if let issue {
                    IssueText(issue).accessibilityIdentifier(AccessibilityID.Mode.Agents.renameProblem)
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
                    Text(note).accessibilityIdentifier(AccessibilityID.Mode.Agents.defaultName)
                }
                if let note = AgentsSettingsModel.placeNote(row) {
                    Text(note)
                }
                if let trouble = AgentsSettingsModel.placeTrouble(row) {
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
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.useDefaultName)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.renameCancel)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.renameIssue(row.id, name: name) != nil || model.namesProblem != nil)
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.renameSave)
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

struct AgentPhrasesReference: View {
    @ObservedObject var model: AgentsSettingsModel
    let onDone: () -> Void

    static let exampleName = "Backend"
    static let renameExample = "\u{201C}rename this conversation to \(exampleName)\u{201D}"
    static let routingExample = "\u{201C}tell \(exampleName) run the unit tests\u{201D} sends only that instruction to \(exampleName)."

    nonisolated static func phrases(readsReplies: Bool) -> [HelpPhrase] {
        SpokenHelp.agentPhrases(name: exampleName, readsReplies: readsReplies).map { HelpPhrase(said: $0.said, meaning: $0.effect, note: $0.note) }
    }

    var body: some View {
        HelpDialog(title: "What can I say?", height: 560, onDone: onDone) {
            HelpSection {
                Text("Start with \u{201C}tell\u{201D} and a conversation\u{2019}s name to send it an instruction. These examples use a conversation named \u{201C}\(Self.exampleName).\u{201D}")
            }
            HelpSection("Phrases") {
                ForEach(Self.phrases(readsReplies: model.spokenResult.enabled), id: \.self) { HelpPhraseRow(phrase: $0) }
            }
            HelpSection("Where instructions go") {
                Text("Without a name, an instruction goes to the conversation focused when you start speaking. With none focused, nothing is sent.")
                Text(Self.routingExample)
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.example)
                Text("While recording, conversations are numbered. Say \u{201C}conversation\u{201D} and the number to use one without its name.")
            }
            HelpSection("Names") {
                Text("Say \(Self.renameExample) to give the conversation you\u{2019}re talking to a name of your own.")
            }
            HelpSection("While recording") {
                Text("Say \u{201C}what can I say\u{201D} to see this list with your own conversations\u{2019} names and vocabulary.")
            }
        }
        .accessibilityIdentifier(AccessibilityID.Mode.Agents.phrases)
    }
}

struct AgentDataHelp: View {
    var body: some View {
        HelpSection {
            Text("The agent receives each instruction in full, as text, and sends it to its own AI provider under its own settings. \(Branding.appName) doesn\u{2019}t control where the agent sends it.")
        }
        HelpSection("Redaction") {
            Text("Best-effort redaction doesn\u{2019}t apply to what the agent receives.")
            Text("With Rewrite instructions before sending on, your words first go to the rewrite service you chose, after best-effort redaction when Hide recognizable sensitive text is on. The agent then receives the rewritten text in full.")
        }
        HelpSection("Replies") {
            Text("Read Agent Replies Aloud sends nothing unless you choose a summary service. With one, longer replies and the prompts an agent waits on go to that service after best-effort redaction.")
        }
    }
}

