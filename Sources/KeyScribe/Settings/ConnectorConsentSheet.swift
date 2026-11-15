import KeyScribeKit
import SwiftUI

struct ConnectorConsentPresenter: View {
    @ObservedObject var model: CodingAgentsSettingsModel

    var body: some View {
        Color.clear.sheet(item: $model.consent) { request in
            ConnectorConsentSheet(model: model, request: request)
        }
    }
}

struct ConnectorConsentSheet: View {
    @ObservedObject var model: CodingAgentsSettingsModel
    let request: CodingAgentsSettingsModel.ConsentRequest
    @State private var showingAll = false
    @State private var contentHeight: CGFloat = 0

    private static let shownBeforeDisclosure = 4

    private var agent: String { request.connector.kind.displayName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.host(of: request.connector).map { "Connect \($0.displayName)?" } ?? "Connect conversations using this \(agent) setup?").font(.title2.bold())
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
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.consentCancel)
                Button(model.host(of: request.connector).map { "Connect \($0.displayName)" } ?? "Install and Connect") { model.confirm(request) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.consentInstall)
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
            Text("\(Branding.appName) lists the conversations \(host.displayName) runs and sends what you dictate to them through \(host.displayName)\u{2019}s own command, queued behind any turn already running.")
                .fixedSize(horizontal: false, vertical: true)
            Text("It also installs a small plugin in \(host.displayName) so the reply to what you dictate is read aloud. Every conversation connects on its own, and you can disconnect any of them later.")
                .fixedSize(horizontal: false, vertical: true)
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
                DisclosureSection("All \(affected.count) open conversations", isExpanded: $showingAll, headerID: AccessibilityID.Mode.CodingAgents.consentConversations) {
                    ForEach(Array(affected.enumerated()), id: \.offset) { _, name in Text(name).font(.caption) }
                }
            }
            if !excluded.isEmpty {
                Text("\(ListFormatter.localizedString(byJoining: excluded)) \(excluded.count == 1 ? "stays" : "stay") disconnected.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Other setups are unaffected. \(Branding.appName) keeps this connector up to date when it updates; open conversations keep the version they loaded until you reload them.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Installs in").font(.caption).foregroundStyle(.secondary)
                CopyableValue(request.setup.display, value: request.setup.folder.path, what: "folder", of: "this setup")
                    .font(.caption)
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.consentFolder)
            }
            if !affected.isEmpty, let reload = request.connector.kind.reloadCommand {
                Text("Conversations already open may need \(reload).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func lead(_ affected: [String]) -> String {
        let shown = Array(affected.prefix(Self.shownBeforeDisclosure))
        let rest = affected.count - shown.count
        let names = shown + (rest > 0 ? ["\(rest) more"] : [])
        let current = names.isEmpty ? "Future conversations" : "\(ListFormatter.localizedString(byJoining: names + ["future conversations"]))"
        return "\(current) using this setup will connect to \(Branding.appName). You can disconnect individual conversations later."
    }
}
