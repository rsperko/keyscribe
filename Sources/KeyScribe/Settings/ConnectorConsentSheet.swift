import KeyScribeKit
import SwiftUI

struct ConnectorConsentPresenter: View {
    @ObservedObject var model: AgentsSettingsModel

    var body: some View {
        Color.clear.sheet(item: $model.consent) { request in
            ConnectorConsentSheet(model: model, request: request)
        }
    }
}

struct ConnectorConsentSheet: View {
    @ObservedObject var model: AgentsSettingsModel
    let request: AgentsSettingsModel.ConsentRequest
    @State private var showingAll = false
    @State private var contentHeight: CGFloat = 0

    private static let shownBeforeDisclosure = 4

    private var agent: String { request.connector.kind.displayName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.host(of: request.connector).map { "Connect \($0.displayName)?" } ?? "Connect \(agent) conversations using this folder?").font(.title2.bold())
            ScrollView {
                details
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 1), 380))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.consent = nil }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.consentCancel)
                Button(model.host(of: request.connector).map { "Connect \($0.displayName)" } ?? "Install and Connect") { model.confirm(request) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.consentInstall)
            }
        }
        .padding(24).frame(width: 460)
    }

    @ViewBuilder private var details: some View {
        if let host = model.host(of: request.connector) {
            hostDetails(host)
        } else {
            setupDetails
        }
    }

    private func hostDetails(_ host: AgentKind) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(Branding.appName) lists the conversations \(host.displayName) runs and sends what you dictate to them through \(host.displayName)\u{2019}s own command, into a turn already running the way typing there would.")
                .fixedSize(horizontal: false, vertical: true)
            Text("It also installs a small plugin in \(host.displayName) so the reply to what you dictate is read aloud, and so dictation can go to the conversation you are looking at: each \(host.displayName) window tells the plugin which conversation it shows. Every conversation connects on its own, and you can disconnect any of them later.")
                .fixedSize(horizontal: false, vertical: true)
            Text("When a conversation stops for your approval or an answer, the plugin reports what it asks, such as the command or plan to approve; with a summary service chosen in Read Agent Replies Aloud, that goes to the service, after best-effort redaction, to be said in a sentence. The plugin also gives the agent in every conversation a tool for asking \(Branding.appName) to read its reply aloud, which it uses only when you ask.")
                .fixedSize(horizontal: false, vertical: true)
            if let note = request.connector.copy.installNote {
                Text(note).fixedSize(horizontal: false, vertical: true)
            }
            Text("\(Branding.appName) runs nothing of \(host.displayName)\u{2019}s until you connect it, and keeps the plugin up to date. Uninstalling the plugin disconnects \(host.displayName).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var setupDetails: some View {
        let affected = model.affected(by: request)
        let excluded = model.stayingDisconnected(by: request)
        return VStack(alignment: .leading, spacing: 14) {
            Text(lead(affected)).fixedSize(horizontal: false, vertical: true)
            if affected.count > Self.shownBeforeDisclosure {
                DisclosureSection("All \(affected.count) open conversations", isExpanded: $showingAll, headerID: AccessibilityID.Mode.Agents.consentConversations) {
                    ForEach(Array(affected.enumerated()), id: \.offset) { _, name in Text(name).font(.caption) }
                }
            }
            if !excluded.isEmpty {
                Text("\(ListFormatter.localizedString(byJoining: excluded)) \(excluded.count == 1 ? "stays" : "stay") disconnected.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Other configuration folders are unaffected. \(Branding.appName) keeps this connector up to date when it updates; open conversations keep the version they loaded until you reload them.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Installs in").font(.caption).foregroundStyle(.secondary)
                CopyableValue(request.setup.display, value: request.setup.folder.path, what: "configuration folder", of: "this connection")
                    .font(.caption)
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.consentFolder)
            }
            if !affected.isEmpty, let reload = request.connector.kind.reloadCommand {
                Text("Conversations already open may need \(reload).").font(.caption).foregroundStyle(.secondary)
            } else if !affected.isEmpty, let resume = request.connector.kind.resumeCommand {
                Text("Conversations already open may need to be quit and reopened with \(resume).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func lead(_ affected: [String]) -> String {
        let shown = Array(affected.prefix(Self.shownBeforeDisclosure))
        let rest = affected.count - shown.count
        let names = shown + (rest > 0 ? ["\(rest) more"] : [])
        let current = names.isEmpty ? "Future conversations" : "\(ListFormatter.localizedString(byJoining: names + ["future conversations"]))"
        return "\(current) using this folder will connect to \(Branding.appName). You can disconnect individual conversations later."
    }
}
