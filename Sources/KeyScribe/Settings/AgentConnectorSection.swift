import AppKit
import KeyScribeKit
import SwiftUI

struct ConnectorSetupsProblemSection: View {
    @ObservedObject var model: CodingAgentsSettingsModel

    var body: some View {
        if let problem = model.setupsProblem {
            Section("Connectors") {
                VStack(alignment: .leading, spacing: 8) {
                    IssueText("Connector choices could not be loaded, so no connector can connect.")
                    Text(problem).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Restore the file, then try again. If you remove it, every connector must be installed again.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Try Again") { Task { await model.retrySetups() } }
                            .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.reloadSetups)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.setups.url]) }
                            .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.showSetupsFile)
                        Spacer()
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.setupsProblem)
            }
        }
    }
}

struct AgentConnectorSection: View {
    @ObservedObject var model: AgentConnectorModel
    let onInstall: (ConnectorSetupModel) -> Void

    var body: some View {
        Section(model.kind.displayName) {
            if let problem = model.discoveryProblem {
                IssueText(problem, severity: .advisory)
            }
            ForEach(model.setups) { setup in
                ConnectorSetupBlock(setup: setup, showsFolderInTitle: model.setups.count > 1, onInstall: { onInstall(setup) })
            }
        }
        .task { await model.refresh() }
    }
}

private struct ConnectorSetupBlock: View {
    @ObservedObject var setup: ConnectorSetupModel
    let showsFolderInTitle: Bool
    let onInstall: () -> Void
    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(title: title, result: statusText, help: setup.copy.help, combinesAccessibilityChildren: false, hasError: setup.hasError) {
                primaryAction
            }
            .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.connectorStatus)
            CopyableValue(setup.display, value: setup.folder.path, what: "folder", of: "this setup")
                .font(.caption)
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.setupFolder)
            Text(usage).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.summary)
            issue
            if setup.showsRemovalWarning {
                IssueText(setup.copy.stillConnected(setup.lingering), severity: .advisory)
            }
            if !setup.manualUninstall.isEmpty {
                manualUninstall
            }
            if setup.needsReload {
                Text(setup.copy.reloadHint).font(.caption).foregroundStyle(.secondary)
            }
            if setup.offersUninstall {
                uninstallButton
            }
        }
        .confirmationDialog(setup.copy.uninstallTitle, isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { Task { await setup.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(setup.copy.uninstallMessage)
        }
    }

    private var title: String {
        showsFolderInTitle ? "Connector in \(setup.display)" : "Connector"
    }

    private var usage: String {
        switch setup.usedBy.count {
        case 0: "No open conversations use this folder."
        case 1: "Used by \(setup.usedBy[0])."
        default: "Used by \(ListFormatter.localizedString(byJoining: setup.usedBy))."
        }
    }

    private var uninstallButton: some View {
        HStack {
            Spacer()
            Button("Uninstall Connector\u{2026}", role: .destructive) { confirmingRemove = true }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.red)
                .disabled(setup.operation != nil)
                .accessibilityLabel("Uninstall \(setup.connector.kind.displayName) connector in \(setup.display)")
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.remove)
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
        .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.manualUninstall)
    }

    private var statusText: String {
        if let operation = setup.operation { return operation }
        return switch setup.state {
        case .checking: "Checking\u{2026}"
        case .toolNotFound: setup.copy.toolNotFoundLabel
        case .toolTooOld: setup.copy.toolTooOldLabel
        case .unavailable: "Unavailable"
        case .failed: "Something went wrong"
        case .removalUnfinished: "Uninstall not finished"
        case .status(.ready): "Installed"
        case .status(.notInstalled): "Not installed"
        case .status(.outdated): "Update available"
        case .status(.disabled): setup.copy.disabledLabel
        case .status(.unknown): "Unknown"
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if setup.operation == nil {
            switch setup.state {
            case .status(.notInstalled):
                Button("Install\u{2026}", action: onInstall)
                    .accessibilityLabel("Install \(setup.connector.kind.displayName) connector in \(setup.display)")
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.install)
            case .failed:
                Button("Try Again") { Task { await setup.retry() } }
                    .accessibilityLabel("Try again for \(setup.connector.kind.displayName) connector in \(setup.display)")
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.tryAgain)
            case .status(.outdated):
                Button("Update") { Task { await setup.update() } }
                    .accessibilityLabel("Update \(setup.connector.kind.displayName) connector in \(setup.display)")
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.update)
            case .removalUnfinished:
                Button("Finish Uninstalling") { Task { await setup.remove() } }
                    .accessibilityLabel("Finish uninstalling \(setup.connector.kind.displayName) connector in \(setup.display)")
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.finishUninstalling)
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
        case .unavailable:
            IssueText(setup.copy.unavailable)
        case .failed(let message):
            IssueText(message.isEmpty ? setup.copy.noReason : message)
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
