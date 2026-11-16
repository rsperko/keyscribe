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
    @State private var revealingConnections = false

    private var rewriteNeedsService: Bool {
        guard let rewrite = mode.aiRewrite else { return false }
        return !connections.contains { $0.id == rewrite.connection }
    }

    var body: some View {
        ScrollViewReader { scroll in
            editor(scroll)
        }
    }

    private func editor(_ scroll: ScrollViewProxy) -> some View {
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
                destinationSection
                connectionsSection
            } else {
                connectionsSection
                destinationSection
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
        .sheet(isPresented: $agents.showingChooser, onDismiss: {
            if revealingConnections {
                revealingConnections = false
                scroll.scrollTo(AccessibilityID.Mode.Agents.openConnections, anchor: .top)
            }
        }) {
            AgentDestinationChooser(model: agents, onOpenConnections: {
                revealingConnections = true
                agents.showingChooser = false
            }) { agents.showingChooser = false }
        }
        .sheet(isPresented: $showingPhrases) {
            AgentPhrasesReference(model: agents) { showingPhrases = false }
        }
        .background { if !agents.showingChooser { ConnectorConsentPresenter(model: agents) } }
    }

    private var destinationSection: some View {
        Section("Where instructions go") {
            LabeledContent("Send to") {
                HStack(spacing: 8) {
                    if case .unavailable = agents.destination {
                        Circle().fill(.red).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                    Text(agents.destination.title).lineLimit(1).truncationMode(.middle)
                        .help(agents.destination.title)
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.destination)
                    Button("Change\u{2026}") { agents.showingChooser = true }
                        .fixedSize()
                        .accessibilityLabel("Change where instructions go")
                        .accessibilityHint("Nothing is sent.")
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.sendTo)
                }
            }
            if case .unavailable(_, let problem) = agents.destination {
                IssueText(problem).accessibilityIdentifier(AccessibilityID.Mode.Agents.sendToProblem)
            }
            AgentSavedChoicesProblems(model: agents)
            VStack(alignment: .leading, spacing: 4) {
                if let example = agents.sendToExample {
                    Text(example).accessibilityIdentifier(AccessibilityID.Mode.Agents.example)
                }
                Text(AgentsSettingsModel.addressedNote).font(.caption).foregroundStyle(.secondary)
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
        }
        .id(AccessibilityID.Mode.Agents.openConnections)
    }
}

