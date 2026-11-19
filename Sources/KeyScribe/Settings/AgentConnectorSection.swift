import AppKit
import KeyScribeKit
import SwiftUI

struct ConnectorSetupsProblemSection: View {
    @ObservedObject var model: AgentsSettingsModel

    var body: some View {
        if let problem = model.integrationsProblem {
            Section("Integrations") {
                VStack(alignment: .leading, spacing: 8) {
                    IssueText("Two of this build's agent integrations conflict, so agents are off.")
                    Text(problem).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("This is a problem in how \(Branding.appName) was built, not in your settings. Report it to whoever made this build.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.integrationsProblem)
            }
        }
        if let problem = model.setupsProblem {
            Section("Connectors") {
                VStack(alignment: .leading, spacing: 8) {
                    IssueText("Connector choices could not be loaded, so no connector can connect.")
                    Text(problem).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Restore the file, then try again. If you remove it, every connector must be installed again.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Try Again") { Task { await model.retrySetups() } }
                            .accessibilityIdentifier(AccessibilityID.Mode.Agents.reloadSetups)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.setups.url]) }
                            .accessibilityIdentifier(AccessibilityID.Mode.Agents.showSetupsFile)
                        Spacer()
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.setupsProblem)
            }
        }
    }
}

struct AgentIntegrationRow: View {
    @ObservedObject var agents: AgentsSettingsModel
    let id: String
    @State private var expanded = false

    var body: some View {
        if let connector = agents.connectors.first(where: { $0.kind.id == id }) {
            ConnectorRow(
                connector: connector, available: available, open: open, awaitingReload: agents.awaitingReload(of: connector).map(\.id),
                onConnect: { agents.requestInstall($0, of: connector) },
                onAddFolder: { ConnectorFolderPicker.choose(for: connector).flatMap { agents.choose(folder: $0, for: connector) } },
                onShow: { agents.showOnly($0, title: ConnectionSummary.awaitingReloadTitle(connector.kind.displayName)) })
        } else if let host = agents.hosts.first(where: { $0.id == id }) {
            let on = agents.isTurnedOn(host)
            VStack(alignment: .leading, spacing: 6) {
                DisclosureSection(isExpanded: $expanded, headerID: AccessibilityID.Mode.Agents.integration(id)) {
                    DisclosureSummaryLabel(
                        title: host.displayName,
                        summary: ConnectionSummary.line(setup: on ? nil : "Not set up", available: available, open: open))
                } content: {
                    SettingRow(
                        title: "Reach conversations in \(host.displayName)",
                        help: "Sends what you say to \(host.displayName)\u{2019}s conversations through its own command. \(Branding.appName) runs nothing of \(host.displayName)\u{2019}s until this is on.")
                    {
                        Toggle("", isOn: Binding(get: { agents.isTurnedOn(host) }, set: { agents.setTurnedOn(host, $0) })).labelsHidden()
                            .accessibilityIdentifier(AccessibilityID.Mode.Agents.host(host.id))
                    }
                }
                if let problem = agents.problem(of: host) {
                    IssueText(problem, severity: .advisory)
                }
            }
        }
    }

    private var available: Int { agents.rows.filter { $0.countsUnder == id && $0.connected }.count }
    private var open: Int { agents.rows.filter { $0.countsUnder == id && !$0.lastSeen }.count }
}

private struct ConnectorRow: View {
    @ObservedObject var connector: AgentConnectorModel
    let available: Int
    let open: Int
    let awaitingReload: [String]
    let onConnect: (ConnectorSetupModel) -> Void
    let onAddFolder: () -> String?
    let onShow: ([String]) -> Void
    @State private var expanded = false
    @State private var folderProblem: String?

    var body: some View {
        let failing = connector.setups.first(where: \.hasError)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                DisclosureSection(
                    headerOnly: $expanded, hasError: failing != nil,
                    headerID: AccessibilityID.Mode.Agents.integration(connector.kind.id)
                ) {
                    DisclosureSummaryLabel(
                        title: connector.kind.displayName,
                        summary: ConnectionSummary.line(setup: connector.setupStatus, available: available, open: open, folders: connector.setups.count))
                }
                if let connectable = connector.connectableSetup {
                    Button("Connect\u{2026}") { onConnect(connectable) }
                        .fixedSize()
                        .accessibilityLabel("Connect \(connector.kind.displayName)")
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.integrationConnect(connector.kind.id))
                }
            }
            if expanded {
                folders
            } else if let message = failing?.failureMessage {
                IssueText(message)
            }
            if let problem = connector.discoveryProblem {
                IssueText(problem, severity: .advisory)
            }
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configuration folders")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(connector.setups) { setup in
                ConnectorFolderRow(
                    setup: setup, canForget: connector.canForget(setup), onInstall: { onConnect(setup) },
                    onForget: { connector.forget(setup) }, details: { await connector.details(for: setup) })
            }
            Button("Add Folder\u{2026}") { folderProblem = onAddFolder() }
                .accessibilityLabel("Add a \(connector.kind.displayName) \(connector.copy.folderNoun)")
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.addFolder)
            if let folderProblem {
                IssueText(folderProblem, severity: .advisory)
            }
            if let purpose = connector.copy.purpose, !connector.setups.contains(where: \.isEnrolled) {
                Text(purpose).font(.caption).foregroundStyle(.secondary)
            }
            if !awaitingReload.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    IssueText(ConnectionSummary.awaitingReload(awaitingReload.count, for: connector.kind), severity: .advisory)
                    Button("View affected conversations\u{2026}") { onShow(awaitingReload) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.viewAwaitingReload)
                }
            }
            HelpLink(
                "How \(connector.kind.displayName) connects",
                id: AccessibilityID.Mode.Agents.howItConnects(connector.kind.id)
            ) {
                HelpSection { Text(connector.copy.help) }
                if !connector.copy.reloadHint.isEmpty {
                    HelpSection("Conversations already open") { Text(connector.copy.reloadHint) }
                }
                HelpSection("Configuration folders") { Text(connector.copy.foldersHelp ?? Self.foldersHelp(connector.kind.displayName)) }
            }
        }
        .onChange(of: connector.setups.count) { _, _ in folderProblem = nil }
    }

    static func foldersHelp(_ agent: String) -> String {
        "A configuration folder is where \(agent) loads its settings from. \(Branding.appName) lists the default folder, the folders its connector is installed in, the folders open conversations use, and the one your login shell sets. If you run \(agent) with another folder, choose Add Folder\u{2026} to install the connector there; each folder is connected and removed on its own."
    }
}

@MainActor
enum ToolPicker {
    static func choose(program: String, agent: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        panel.message = "Choose the \(program) command \(Branding.appName) should run for \(agent)."
        panel.prompt = "Use Command"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

@MainActor
enum ConnectorFolderPicker {
    static func choose(for connector: AgentConnectorModel) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = false
        panel.directoryURL = connector.connector.defaultFolder.deletingLastPathComponent()
        panel.message = connector.copy.folderNoun == "configuration folder"
            ? "Choose the folder \(connector.kind.displayName) loads its configuration from."
            : "Choose a \(connector.kind.displayName) \(connector.copy.folderNoun)."
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

enum ConnectionSummary {
    static func line(setup: String?, available: Int, open: Int = 0, folders: Int = 1) -> String {
        var parts = setup.map { [$0] } ?? []
        if available > 0 {
            parts.append(available == 1 ? "1 conversation available" : "\(available) conversations available")
        } else if open > 0 {
            parts.append(open == 1 ? "1 open, not connected" : "\(open) open, none connected")
        } else if setup == nil {
            parts.append("No conversations open")
        }
        if folders > 1 { parts.append("\(folders) configuration folders") }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func awaitingReload(_ count: Int, for kind: AgentKind) -> String {
        guard let reload = kind.reloadCommand else {
            if let resume = kind.resumeCommand {
                return count == 1
                    ? "1 conversation needs the connector loaded. Quit it and reopen it with \(resume)."
                    : "\(count) conversations need the connector loaded. Quit each and reopen it with \(resume)."
            }
            return count == 1 ? "1 conversation hasn\u{2019}t connected yet." : "\(count) conversations haven\u{2019}t connected yet."
        }
        return count == 1
            ? "1 conversation needs the connector loaded. Run \(reload) in it, or restart it."
            : "\(count) conversations need the connector loaded. Run \(reload) in each, or restart them."
    }

    static func awaitingReloadTitle(_ agent: String) -> String {
        "\(agent) conversations that need the connector loaded"
    }
}

extension AgentConnectorModel {
    var setupStatus: String? {
        if let failing = setups.first(where: \.hasError) {
            return setups.count > 1 ? "\(failing.statusText) in \(failing.display)" : failing.statusText
        }
        if let operation = setups.lazy.compactMap(\.operation).first { return operation }
        let installed = setups.filter(\.isInstalled)
        if !installed.isEmpty {
            return installed.allSatisfy { $0.state == .status(.disabled) } ? copy.disabledLabel : nil
        }
        if let enrolled = setups.first(where: \.isEnrolled) { return enrolled.statusText }
        if setups.contains(where: { $0.state == .checking }) { return "Checking\u{2026}" }
        if let missing = setups.first(where: { $0.toolMissing || $0.state == .unavailable }) {
            return missing.statusText
        }
        if let old = setups.first(where: { if case .toolTooOld = $0.state { true } else { false } }) { return old.statusText }
        return "Not set up"
    }

    var connectableSetup: ConnectorSetupModel? {
        guard !setups.contains(where: { $0.isEnrolled || $0.isInstalled || $0.operation != nil }),
              let setup = setups.first(where: \.isDefault), setup.state == .status(.notInstalled)
        else { return nil }
        return setup
    }
}

private struct ConnectorFolderRow: View {
    @ObservedObject var setup: ConnectorSetupModel
    let canForget: Bool
    let onInstall: () -> Void
    let onForget: () -> Void
    let details: () async -> String
    @State private var confirmingRemove = false
    @State private var lookedIn = false
    @State private var toolProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 6) {
                    if let name = setup.name {
                        Text(name).lineLimit(1).fixedSize()
                    }
                    Text(setup.display).lineLimit(1).truncationMode(.middle).help(setup.folder.path)
                        .foregroundStyle(setup.name == nil ? .primary : .secondary)
                    if setup.hasError {
                        Circle().fill(.red).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(([setup.name, setup.display, setup.statusText].compactMap { $0 } + (setup.hasError ? ["Needs attention"] : [])).joined(separator: ", "))
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.folderRow)
                Spacer(minLength: 8)
                Text(setup.statusText).font(.callout).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .accessibilityHidden(true)
                primaryAction
                actions
            }
            issue
            if let chosen = setup.chosenTool {
                Text("Uses the command you chose: \(ConnectorFolders.display(URL(fileURLWithPath: chosen)))")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let toolProblem {
                IssueText(toolProblem, severity: .advisory)
            }
            if let searched = setup.lookedIn {
                DisclosureSection("Where \(Branding.appName) looked", isExpanded: $lookedIn, headerID: AccessibilityID.Mode.Agents.lookedIn) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let problem = setup.shellProblem, setup.choosesTool {
                            IssueText("Your login shell could not be read, so its PATH is missing here: \(problem)", severity: .advisory)
                        }
                        ForEach(searched, id: \.path) { place in
                            Text("\(ConnectorFolders.display(URL(fileURLWithPath: place.path))) \u{2014} \(place.source.label)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            if setup.showsRemovalWarning {
                IssueText(setup.copy.stillConnected(setup.lingering), severity: .advisory)
            }
            if let note = setup.uninstallWithoutToolNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if !setup.manualUninstall.isEmpty {
                manualUninstall
            }
        }
        .confirmationDialog(setup.copy.uninstallTitle, isPresented: $confirmingRemove, titleVisibility: .visible) {
            if setup.undoesOnUninstall {
                Button(setup.copy.undoOnUninstallLabel, role: .destructive) { Task { await setup.remove(undoing: true) } }
            }
            Button("Uninstall", role: .destructive) { Task { await setup.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(setup.undoesOnUninstall ? setup.copy.uninstallMessage + " " + setup.copy.undoOnUninstallNote : setup.copy.uninstallMessage)
        }
    }

    private var setupName: String {
        "\(setup.connector.kind.displayName) \(setup.copy.setupTitle.lowercased()) in \(setup.display)"
    }

    private var actions: some View {
        Menu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([setup.folder]) }
            Button("Copy Path") { _ = TextInserter.copyToClipboard(setup.folder.path) }
            Button("Copy Details") { Task { _ = TextInserter.copyToClipboard(await details()) } }
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.copyDetails)
            if let program = setup.connector.toolProgram {
                Divider()
                Button("Choose \(program) Command\u{2026}") { chooseTool() }
                if setup.chosenTool != nil {
                    Button("Find \(program) Automatically") { Task { toolProblem = await setup.choose(tool: nil) } }
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.findToolAutomatically)
                }
            }
            if setup.offersUninstall || canForget {
                Divider()
            }
            if setup.offersUninstall {
                Button("Uninstall \(setup.copy.setupTitle)\u{2026}", role: .destructive) { confirmingRemove = true }
                    .disabled(setup.operation != nil)
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.remove)
            }
            if canForget {
                Button("Remove from List", action: onForget)
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.forgetFolder)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More for \(setup.display)")
        .accessibilityLabel("More for \(setupName)")
        .accessibilityIdentifier(AccessibilityID.Mode.Agents.folderActions)
    }

    private var manualUninstall: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lead = setup.manualUninstallLead {
                Text(lead).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(setup.manualUninstall, id: \.self) { command in
                CopyableValue(command, value: command, what: "command", of: "uninstalling the connector")
                    .font(.caption.monospaced())
            }
        }
        .accessibilityIdentifier(AccessibilityID.Mode.Agents.manualUninstall)
    }

    private func chooseTool() {
        guard let program = setup.connector.toolProgram, let url = ToolPicker.choose(program: program, agent: setup.connector.kind.displayName) else { return }
        Task { toolProblem = await setup.choose(tool: url) }
    }

    @ViewBuilder private var primaryAction: some View {
        if setup.operation == nil {
            switch setup.state {
            case .toolNotFound where setup.choosesTool, .toolNotWorking where setup.choosesTool:
                Button("Choose\u{2026}") { chooseTool() }
                    .accessibilityLabel("Choose the \(setup.connector.toolProgram ?? "") command for \(setupName)")
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.chooseTool)
            case .status(.notInstalled) where setup.offersReinstall:
                Button("Reinstall") { Task { await setup.install() } }
                    .accessibilityLabel("Reinstall \(setupName)")
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.install)
            case .status(.notInstalled):
                Button("Install\u{2026}", action: onInstall)
                    .accessibilityLabel("Install \(setupName)")
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.install)
            case .failed, .unconfirmed:
                Button("Try Again") { Task { await setup.retry() } }
                    .accessibilityLabel("Try again for \(setupName)")
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.tryAgain)
            case .status(.outdated):
                Button("Update") { Task { await setup.update() } }
                    .accessibilityLabel("Update \(setupName)")
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.update)
            case .broken:
                Button("Repair") { Task { await setup.update() } }
                    .accessibilityLabel("Repair \(setupName)")
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.update)
            case .removalUnfinished:
                Button("Finish Uninstalling") { Task { await setup.remove() } }
                    .accessibilityLabel("Finish uninstalling \(setupName)")
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.finishUninstalling)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var issue: some View {
        switch setup.state {
        case .toolNotFound:
            IssueText(setup.copy.toolNotFoundAdvice, severity: .advisory)
        case .toolNotWorking(let check):
            IssueText(check.describe(command: setup.search?.tool.map { ConnectorFolders.display(URL(fileURLWithPath: $0.path)) } ?? setup.connector.toolProgram ?? ""), severity: .advisory)
            if setup.choosesTool {
                IssueText("Choose the command \(Branding.appName) should use, or fix this one and check again.", severity: .advisory)
            }
        case .toolTooOld(let found):
            IssueText(setup.copy.toolTooOldAdvice(found), severity: .advisory)
        case .unavailable, .failed, .broken, .unconfirmed:
            if let message = setup.failureMessage { IssueText(message) }
        case .status(.disabled):
            IssueText(setup.copy.disabledAdvice, severity: .advisory)
        case .removalUnfinished(let message):
            IssueText(setup.copy.removalUnfinishedAdvice, severity: .advisory)
            if let message { IssueText(message.isEmpty ? setup.copy.noReason : message) }
        case .status(.unknown):
            IssueText(setup.copy.listUnreadable, severity: .advisory)
        default:
            EmptyView()
        }
    }
}

extension ConnectorSetupModel {
    var statusText: String {
        if let operation = operation { return operation }
        return switch state {
        case .checking: "Checking\u{2026}"
        case .toolNotFound: copy.toolNotFoundLabel
        case .toolNotWorking: copy.toolNotWorkingLabel
        case .toolTooOld: copy.toolTooOldLabel
        case .unavailable: "Unavailable"
        case .failed, .unconfirmed: "Something went wrong"
        case .removalUnfinished: "Uninstall not finished"
        case .broken: "Not working"
        case .status(.ready): "Installed"
        case .status(.notInstalled): "Not installed"
        case .status(.outdated): "Update available"
        case .status(.disabled): copy.disabledLabel
        case .status(.unknown): "Unknown"
        case .status(.notOpen): "Not open"
        }
    }

    var failureMessage: String? {
        switch state {
        case .unavailable: copy.unavailable
        case .failed(let message), .broken(let message), .unconfirmed(let message): message.isEmpty ? copy.noReason : message
        case .removalUnfinished(let message): message.flatMap { $0.isEmpty ? nil : $0 } ?? copy.removalUnfinishedAdvice
        default: nil
        }
    }
}
