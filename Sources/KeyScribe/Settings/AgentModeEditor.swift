import KeyScribeKit
import SwiftUI

struct AgentModeEditor: View {
    let mode: Mode
    @ObservedObject var agents: AgentsSettingsModel
    let connections: [Connection]
    let trigger: ModeTrigger
    let onUpdate: (Mode) -> Void
    let vocabulary: ModeVocabularyRow
    let rewrite: ModeAISection
    let hidesSensitiveText: Binding<Bool>
    let leavesOutOfHistory: Binding<Bool>
    @State private var advancedExpanded = false
    @State private var showingPhrases = false

    private var rewriteNeedsService: Bool {
        guard let rewrite = mode.aiRewrite else { return false }
        return !connections.contains { $0.id == rewrite.connection }
    }

    var body: some View {
        Form {
            Section {
                PaneDetailHeader(
                    systemImage: "terminal",
                    title: mode.name,
                    subtitle: ModeSummary.whenRuns(mode),
                    badges: { PaneBadge("Built in") })
            }
            Section("How to start \(mode.name)") {
                ModeTriggerRow(mode: mode, onUpdate: onUpdate, label: "Shortcut")
                PressStyleRow(trigger: trigger)
                TriggerConflictLabel(conflict: trigger.conflict, mode: mode)
                ExtraTriggersNote(mode: mode)
            }
            ConnectorSetupsProblemSection(model: agents)
            if agents.hasAnyConnection {
                routingSection
                connectionsSection
            } else {
                connectionsSection
                routingSection
            }
            SpokenResultSection(model: agents, connections: connections)
            Section {
                DisclosureSection(headerOnly: $advancedExpanded, hasError: rewriteNeedsService, headerID: AccessibilityID.Mode.Agents.advanced) {
                    DisclosureSummaryLabel(title: "Advanced", summary: "Vocabulary, rewriting before sending, and history")
                }
            }
            if advancedExpanded {
                Section("Words") { vocabulary }
                rewrite
                if mode.aiRewrite != nil {
                    Section("Data sent with AI") {
                        SettingRow(
                            title: "Hide recognizable sensitive text",
                            help: "Best-effort redaction replaces recognizable sensitive spans with tokens before the AI rewrite, then restores them on this Mac. It protects only the rewrite request: the agent still receives your words in full.")
                        {
                            Toggle("", isOn: hidesSensitiveText).labelsHidden()
                                .accessibilityIdentifier(AccessibilityID.Mode.Editor.privacy)
                        }
                    }
                }
                Section("History") {
                    SettingRow(
                        title: "Do not save this mode in history",
                        help: "When on, what you send to agents is never written to local history. Other modes still record per your History setting.")
                    {
                        Toggle("", isOn: leavesOutOfHistory).labelsHidden()
                            .accessibilityIdentifier(AccessibilityID.Mode.Editor.excludeFromHistory)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .task { await agents.refresh() }
        .sheet(isPresented: $agents.showingConversations) {
            AgentConversationList(model: agents) { agents.showingConversations = false }
        }
        .sheet(isPresented: $showingPhrases) {
            AgentPhrasesReference(model: agents) { showingPhrases = false }
        }
        .background { if !agents.showingConversations { ConnectorConsentPresenter(model: agents) } }
    }

    private var routingSection: some View {
        Section("Where instructions go") {
            VStack(alignment: .leading, spacing: 4) {
                Text(AgentsSettingsModel.routingNote)
                if let example = agents.routingExample {
                    Text(example).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.example)
                }
                HStack {
                    Button("What can I say?") { showingPhrases = true }
                        .buttonStyle(.link)
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.whatCanISay)
                    Spacer()
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Label(
                "The agent receives what you say and sends it to its own AI provider under its own settings. Best-effort redaction does not apply to it.",
                systemImage: "arrow.up.forward.app")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connectionsSection: some View {
        Section("Connections") {
            ForEach(agents.integrationIDs, id: \.self) { id in
                AgentIntegrationRow(agents: agents, id: id)
            }
            LabeledContent("Conversations") {
                HStack(spacing: 8) {
                    Text(agents.conversationsSummary).foregroundStyle(.secondary)
                    Button("Manage\u{2026}") { agents.showingConversations = true }
                        .fixedSize()
                        .accessibilityLabel("Manage conversations")
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.manageConversations)
                }
            }
            AgentSavedChoicesProblems(model: agents)
        }
    }
}

