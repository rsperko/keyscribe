import KeyScribeKit
import SwiftUI

struct AgentConnectorSection: View {
    @ObservedObject var model: AgentConnectorModel
    @State private var confirmingRemove = false

    var body: some View {
        Section(model.kind.displayName) {
            SettingRow(title: "Connector", result: statusText, help: model.copy.help, combinesAccessibilityChildren: false) {
                primaryAction
            }
            .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.connectorStatus)
            issue
            if let problem = model.discoveryProblem {
                IssueText(problem, severity: .advisory)
            }
            if model.showsRemovalWarning {
                IssueText(model.copy.stillConnected(model.connectedCount), severity: .advisory)
            }
            if !model.manualUninstall.isEmpty {
                manualUninstall
            }
            if model.isInstalled {
                Text(summary).font(.callout)
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.summary)
                if model.connectedCount < model.sessions || model.needsReload {
                    Text(model.copy.reloadHint).font(.caption).foregroundStyle(.secondary)
                }
                uninstallButton
            } else if model.offersUninstall {
                uninstallButton
            }
        }
        .task { await model.refresh() }
        .confirmationDialog(model.copy.uninstallTitle, isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { Task { await model.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.copy.uninstallMessage)
        }
    }

    private var uninstallButton: some View {
        HStack {
            Spacer()
            Button("Uninstall Connector\u{2026}", role: .destructive) { confirmingRemove = true }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.red)
                .disabled(model.operation != nil)
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.remove)
        }
    }

    private var manualUninstall: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lead = model.manualUninstallLead {
                Text(lead).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.manualUninstall, id: \.self) { command in
                CopyableValue(command, value: command, what: "command", of: "uninstalling the connector")
                    .font(.caption.monospaced())
            }
        }
        .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.manualUninstall)
    }

    private var summary: String {
        switch (model.sessions, model.connectedCount) {
        case (0, _): model.copy.noSessions
        case (let total, let connected): "\(connected) of \(total) \(total == 1 ? "conversation" : "conversations") connected"
        }
    }

    private var statusText: String {
        if let operation = model.operation { return operation }
        return switch model.state {
        case .checking: "Checking…"
        case .toolNotFound: model.copy.toolNotFoundLabel
        case .toolTooOld: model.copy.toolTooOldLabel
        case .unavailable: "Unavailable"
        case .failed: "Something went wrong"
        case .removalUnfinished: "Uninstall not finished"
        case .status(.ready): "Installed"
        case .status(.notInstalled): "Not installed"
        case .status(.outdated): "Update available"
        case .status(.disabled): model.copy.disabledLabel
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
        switch model.state {
        case .status(.notInstalled), .failed:
            Button("Install") { Task { await model.install() } }
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.install)
        case .status(.outdated):
            Button("Update") { Task { await model.update() } }
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.update)
        case .removalUnfinished:
            Button("Finish Uninstalling") { Task { await model.remove() } }
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.finishUninstalling)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var issue: some View {
        switch model.state {
        case .toolNotFound:
            IssueText(model.copy.toolNotFoundAdvice, severity: .advisory)
        case .toolTooOld(let found):
            IssueText(model.copy.toolTooOldAdvice(found), severity: .advisory)
        case .unavailable:
            IssueText(model.copy.unavailable)
        case .failed(let message):
            IssueText(message.isEmpty ? model.copy.noReason : message)
        case .status(.disabled):
            IssueText(model.copy.disabledAdvice, severity: .advisory)
        case .removalUnfinished(let message):
            IssueText(model.copy.removalUnfinishedAdvice, severity: .advisory)
            if let message { IssueText(message.isEmpty ? model.copy.noReason : message) }
        case .status(.unknown):
            IssueText(model.copy.listUnreadable, severity: .advisory)
        default:
            EmptyView()
        }
    }
}
