import KeyScribeKit
import SwiftUI

struct SpokenResultSection: View {
    @ObservedObject var model: CodingAgentsSettingsModel
    let connections: [Connection]
    @State private var advancedExpanded = false

    var body: some View {
        Section("Spoken updates") {
            SettingRow(
                title: "Read updates aloud", result: "Skipped when the conversation is already in front of you.",
                help: "When a conversation you spoke to finishes, waits for approval or an answer, or loses its connector, you hear its name and what happened. A short finished reply is read as it is; a longer one is read as a short summary from the AI service you choose, or announced as finished without one. When \(Branding.appName) can\u{2019}t confirm the conversation is in front, the update plays.")
            {
                Toggle("", isOn: enabled)
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.spokenResultEnabled)
            }
            if model.spokenResult.enabled {
                serviceRows
                if let voice = model.voice {
                    SpokenVoiceRows(voice: voice, selection: self.voice)
                }
                DisclosureSection(isExpanded: $advancedExpanded, headerID: AccessibilityID.Mode.CodingAgents.spokenResultAdvanced) {
                    DisclosureSummaryLabel(title: "Advanced", summary: "Summary instruction and voice files")
                } content: {
                    PromptEditor(
                        title: "Summary instruction",
                        placeholder: "How the AI should sum up a reply\u{2026}",
                        text: model.spokenResult.effectivePrompt,
                        expandID: AccessibilityID.Mode.CodingAgents.spokenResultPromptExpand,
                        expandDoneID: AccessibilityID.Mode.CodingAgents.spokenResultPromptExpandDone
                    ) { value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.spokenResult.prompt = trimmed.isEmpty || trimmed == SpokenResultSettings.defaultPrompt ? nil : value
                    }
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.spokenResultPrompt)
                    HStack {
                        Spacer()
                        Button("Reset to Default") { model.spokenResult.prompt = nil }
                            .disabled(model.spokenResult.prompt == nil)
                            .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.spokenResultReset)
                    }
                    if let voice = model.voice {
                        SpokenVoiceFiles(voice: voice)
                    }
                }
            }
        }
    }

    @ViewBuilder private var serviceRows: some View {
        if connections.isEmpty {
            IssueText("Add an AI service to hear summaries of longer replies and what a waiting prompt asks. Without one, a longer reply is announced as finished.", severity: .advisory)
            HStack {
                Button("Open AI Services") { model.onOpenAIServices?() }
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.spokenResultOpenAIServices)
                Spacer()
            }
        } else {
            SettingRow(title: "AI service", result: boundary, help: serviceHelp) {
                Picker("", selection: service) {
                    Text("None").tag("")
                    if missing {
                        Text("Choose\u{2026}").tag(model.spokenResult.connection)
                    }
                    ForEach(connections) { connection in
                        Text(connection.name).tag(connection.id)
                    }
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.spokenResultService)
            }
            if missing {
                IssueText("That AI service no longer exists. Choose another.")
            }
        }
    }

    private var boundary: String? {
        guard let chosen else { return missing ? nil : "Longer replies are announced as finished. Nothing is sent." }
        return "Long replies and waiting prompts go to \(chosen.name) after best-effort redaction."
    }

    private var serviceHelp: String {
        let name = chosen?.name ?? "the chosen service"
        return "A longer reply is sent to \(name) to be summarized. When a conversation waits on a prompt its connector describes, the prompt\u{2019}s title, the tool call it seems to be about (such as a command to approve) and the agent\u{2019}s last words are sent to say what it asks. Both go after best-effort redaction, which can miss things in code and command output. A short reply is read as it is, without any service; with None, a longer reply is announced as finished. \(Branding.appName) does not save replies or summaries."
    }

    private var chosen: Connection? { connections.first { $0.id == model.spokenResult.connection } }
    private var missing: Bool { chosen == nil && !model.spokenResult.connection.isEmpty }

    private var enabled: Binding<Bool> {
        Binding(get: { model.spokenResult.enabled }, set: { model.spokenResult.enabled = $0 })
    }

    private var service: Binding<String> {
        Binding(get: { model.spokenResult.connection }, set: { model.spokenResult.connection = $0 })
    }

    private var voice: Binding<String> {
        Binding(
            get: { SpokenVoices.resolved(model.spokenResult.voice) },
            set: { model.spokenResult.voice = $0 == SpokenVoices.recommended ? nil : $0 })
    }
}

private struct SpokenVoiceRows: View {
    @ObservedObject var voice: SpokenVoiceModel
    let selection: Binding<String>
    @State private var preview: NaturalSpeech?

    private static let help = "Speech is made on this Mac; what it reads is never sent anywhere."
    private var size: String { ByteCountFormatter.fileStyle.string(fromByteCount: SpokenVoiceModel.approxDownloadBytes) }

    var body: some View {
        voiceRow
        if let error = voice.error {
            IssueText(error, severity: voice.status == .needsAttention ? .failure : .advisory)
        } else if voice.status == .ready, voice.fellBack {
            IssueText("The natural voice couldn\u{2019}t read the last summary, so the macOS voice read it.", severity: .advisory)
        }
    }

    @ViewBuilder private var voiceRow: some View {
        switch voice.status {
        case .ready:
            SettingRow(title: "Voice", help: Self.help, combinesAccessibilityChildren: false) {
                wrapping {
                    Picker("Voice", selection: selection) {
                        ForEach(SpokenVoices.all) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.spokenResultVoice)
                    previewButton
                }
            }
        case .notInstalled:
            SettingRow(
                title: "Voice", result: "Using the macOS voice. Download the natural voice for better speech.",
                help: Self.help, combinesAccessibilityChildren: false)
            {
                wrapping {
                    previewButton
                    Button("Download English \u{00B7} \(size)") { voice.download() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Download the English voice, \(size)")
                        .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.spokenVoiceDownload)
                }
            }
        case .downloading(let phase, let fraction):
            SettingRow(title: "Voice", result: "Downloading \(Int((fraction * 100).rounded()))%", help: Self.help) { progress(phase) }
        case .testing:
            SettingRow(title: "Voice", result: "Testing\u{2026}", help: Self.help) { progress("Testing voice\u{2026}") }
        case .removing:
            SettingRow(title: "Voice", result: "Removing\u{2026}", help: Self.help) { progress("Removing\u{2026}") }
        case .needsAttention:
            SettingRow(title: "Voice", result: "Needs attention", help: Self.help, combinesAccessibilityChildren: false) {
                Button("Reinstall voice") { voice.reinstall() }
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.spokenVoiceReinstall)
            }
        }
    }

    private func wrapping(@ViewBuilder _ content: () -> some View) -> some View {
        let content = content()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .trailing, spacing: 6) { content }
        }
    }

    private var previewButton: some View {
        Button("Preview Voice") { playPreview() }
            .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.spokenResultPreview)
    }

    private func playPreview() {
        let speech = preview ?? makePreview()
        preview = speech
        SpeechSilencer.shared.speak(SpokenVoices.sample, voice: selection.wrappedValue, with: speech)
    }

    private func makePreview() -> NaturalSpeech {
        let speech = SpeechSilencer.shared.registered(voice.makeSpeech())
        speech.onFinished = { [weak speech] in
            guard let speech else { return }
            SpeechSilencer.shared.released(speech)
        }
        return speech
    }

    private func progress(_ phase: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(phase)
        }
    }
}

private struct SpokenVoiceFiles: View {
    @ObservedObject var voice: SpokenVoiceModel

    private var size: String { ByteCountFormatter.fileStyle.string(fromByteCount: SpokenVoiceModel.approxDownloadBytes) }

    var body: some View {
        if voice.canDelete {
            Text("The voice is English and takes about \(size) on this Mac. Deleting it returns playback to the macOS voice until you download it again; your speaker and summary settings are kept.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                PaneDeleteButton(title: "Delete Voice") { voice.requestDelete() }
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.spokenVoiceDelete)
            }
            .confirmationDialog(
                "Delete the voice?",
                isPresented: Binding(get: { voice.pendingDelete }, set: { if !$0 { voice.cancelDelete() } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { voice.confirmDelete() }
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.spokenVoiceDeleteConfirm)
                Button("Cancel", role: .cancel) { voice.cancelDelete() }
                    .accessibilityIdentifier(AccessibilityID.Mode.CodingAgents.spokenVoiceDeleteCancel)
            } message: {
                Text("Summaries are read in the macOS voice until you download it again.")
            }
        }
    }
}
