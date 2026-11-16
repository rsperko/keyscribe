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
            ConnectorRow(connector: connector, available: available, notConnected: notConnected, onConnect: {
                agents.requestInstall($0, of: connector)
            })
        } else if let host = agents.hosts.first(where: { $0.id == id }) {
            let on = agents.isTurnedOn(host)
            VStack(alignment: .leading, spacing: 6) {
                DisclosureSection(isExpanded: $expanded, headerID: AccessibilityID.Mode.Agents.integration(id)) {
                    DisclosureSummaryLabel(
                        title: host.displayName,
                        summary: ConnectionSummary.line(setup: on ? "Turned on" : "Not set up", isSetUp: on, available: available, notConnected: notConnected))
                } content: {
                    SettingRow(
                        title: "Reach conversations in \(host.displayName)",
                        help: "Lists the conversations \(host.displayName) runs and sends what you say to them through \(host.displayName)\u{2019}s own command, into a turn already running the way typing there would. \(Branding.appName) runs nothing of \(host.displayName)\u{2019}s until this is on.")
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

    private var available: Int { agents.rows.filter { $0.agent == id && $0.connected }.count }
    private var notConnected: Int { agents.rows.filter { $0.agent == id && !$0.connected }.count }
}

private struct ConnectorRow: View {
    @ObservedObject var connector: AgentConnectorModel
    let available: Int
    let notConnected: Int
    let onConnect: (ConnectorSetupModel) -> Void
    @State private var expanded = false

    var body: some View {
        let setup = connector.setupStatus
        let failing = connector.setups.first(where: \.hasError)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                DisclosureSection(
                    headerOnly: $expanded, hasError: failing != nil,
                    headerID: AccessibilityID.Mode.Agents.integration(connector.kind.id)
                ) {
                    DisclosureSummaryLabel(
                        title: connector.kind.displayName,
                        summary: ConnectionSummary.line(setup: setup.text, isSetUp: setup.isSetUp, available: available, notConnected: notConnected))
                }
                if let connectable = connector.connectableSetup {
                    Button("Connect\u{2026}") { onConnect(connectable) }
                        .fixedSize()
                        .accessibilityLabel("Connect \(connector.kind.displayName)")
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.integrationConnect(connector.kind.id))
                }
            }
            if expanded {
                ForEach(connector.setups) { setup in
                    ConnectorSetupBlock(setup: setup, showsFolderInTitle: connector.setups.count > 1, onInstall: { onConnect(setup) })
                }
            } else if let message = failing?.failureMessage {
                IssueText(message)
            }
            if let problem = connector.discoveryProblem {
                IssueText(problem, severity: .advisory)
            }
        }
    }
}

enum ConnectionSummary {
    static func line(setup: String, isSetUp: Bool, available: Int, notConnected: Int) -> String {
        var parts = [setup]
        if available > 0 {
            parts.append(available == 1 ? "1 conversation available" : "\(available) conversations available")
        } else if isSetUp, notConnected == 0 {
            parts.append("No conversations open")
        }
        if notConnected > 0 { parts.append("\(notConnected) not connected") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

extension AgentConnectorModel {
    var setupStatus: (text: String, isSetUp: Bool) {
        if let failing = setups.first(where: \.hasError) {
            return (setups.count > 1 ? "\(failing.statusText) in \(failing.display)" : failing.statusText, true)
        }
        if let operation = setups.lazy.compactMap(\.operation).first { return (operation, true) }
        let installed = setups.filter(\.isInstalled)
        if !installed.isEmpty {
            let disabled = installed.allSatisfy { $0.state == .status(.disabled) }
            return (disabled ? copy.disabledLabel : "\(copy.setupTitle) installed", true)
        }
        if let enrolled = setups.first(where: \.isEnrolled) { return (enrolled.statusText, true) }
        if setups.contains(where: { $0.state == .checking }) { return ("Checking\u{2026}", false) }
        if let missing = setups.first(where: { $0.state == .toolNotFound || $0.state == .unavailable }) {
            return (missing.statusText, false)
        }
        if let old = setups.first(where: { if case .toolTooOld = $0.state { true } else { false } }) { return (old.statusText, false) }
        return ("Not set up", false)
    }

    var connectableSetup: ConnectorSetupModel? {
        guard !setups.contains(where: { $0.isEnrolled || $0.isInstalled || $0.operation != nil }),
              let setup = setups.first(where: \.isDefault), setup.state == .status(.notInstalled)
        else { return nil }
        return setup
    }
}

private struct ConnectorSetupBlock: View {
    @ObservedObject var setup: ConnectorSetupModel
    let showsFolderInTitle: Bool
    let onInstall: () -> Void
    @State private var confirmingRemove = false
    @State private var showingUsers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(title: title, result: setup.statusText, help: setup.copy.help, combinesAccessibilityChildren: false, hasError: setup.hasError) {
                primaryAction
            }
            .accessibilityIdentifier(AccessibilityID.Mode.Agents.connectorStatus)
            if let purpose = setup.copy.purpose, !setup.isEnrolled {
                Text(purpose).font(.caption).foregroundStyle(.secondary)
            }
            CopyableValue(setup.display, value: setup.folder.path, what: "folder", of: "this setup")
                .font(.caption)
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.setupFolder)
            if setup.copy.describesUse {
                usage
            }
            issue
            if setup.showsRemovalWarning {
                IssueText(setup.copy.stillConnected(setup.lingering), severity: .advisory)
            }
            if !setup.manualUninstall.isEmpty {
                manualUninstall
            }
            if setup.needsReload, !setup.copy.reloadHint.isEmpty {
                Text(setup.copy.reloadHint).font(.caption).foregroundStyle(.secondary)
            }
            if setup.offersUninstall {
                uninstallButton
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

    private var title: String {
        showsFolderInTitle ? "\(setup.copy.setupTitle) in \(setup.display)" : setup.copy.setupTitle
    }

    @ViewBuilder private var usage: some View {
        let count = setup.usedBy.count
        HStack(spacing: 6) {
            Text(count == 0 ? "No open conversations use this folder." : count == 1 ? "Used by 1 conversation." : "Used by \(count) conversations.")
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.summary)
            if count > 0 {
                Button(showingUsers ? "Hide" : "Show") { showingUsers.toggle() }
                    .buttonStyle(.link)
                    .accessibilityLabel(showingUsers ? "Hide the conversations using this folder" : "Show the conversations using this folder")
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.usedBy)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        if showingUsers, count > 0 {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(setup.usedBy.enumerated()), id: \.offset) { _, name in Text(name) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.leading, 12)
        }
    }

    private var uninstallButton: some View {
        HStack {
            Spacer()
            Button("Uninstall \(setup.copy.setupTitle)\u{2026}", role: .destructive) { confirmingRemove = true }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.red)
                .disabled(setup.operation != nil)
                .accessibilityLabel("Uninstall \(setupName)")
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.remove)
        }
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

    @ViewBuilder private var primaryAction: some View {
        if setup.operation == nil {
            switch setup.state {
            case .status(.notInstalled) where setup.offersReinstall:
                Button("Reinstall") { Task { await setup.install() } }
                    .accessibilityLabel("Reinstall \(setupName)")
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.install)
            case .status(.notInstalled):
                Button("Install\u{2026}", action: onInstall)
                    .accessibilityLabel("Install \(setupName)")
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.install)
            case .failed:
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
        case .toolTooOld(let found):
            IssueText(setup.copy.toolTooOldAdvice(found), severity: .advisory)
        case .unavailable, .failed, .broken:
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
        case .toolTooOld: copy.toolTooOldLabel
        case .unavailable: "Unavailable"
        case .failed: "Something went wrong"
        case .removalUnfinished: "Uninstall not finished"
        case .broken: "Not working"
        case .status(.ready): "Installed"
        case .status(.notInstalled): "Not installed"
        case .status(.outdated): "Update available"
        case .status(.disabled): copy.disabledLabel
        case .status(.unknown): "Unknown"
        }
    }

    var failureMessage: String? {
        switch state {
        case .unavailable: copy.unavailable
        case .failed(let message), .broken(let message): message.isEmpty ? copy.noReason : message
        case .removalUnfinished(let message): message.flatMap { $0.isEmpty ? nil : $0 } ?? copy.removalUnfinishedAdvice
        default: nil
        }
    }
}
