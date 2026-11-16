import KeyScribeKit
import SwiftUI

struct SpokenResultSection: View {
    @ObservedObject var model: AgentsSettingsModel
    let connections: [Connection]
    @State private var optionsExpanded = false

    private static let help = "For messages you dictate, and for work you type when you ask the agent to have \(Branding.appName) tell you when it\u{2019}s done (or run /\(KeyScribePaths.variant.connectorSlug) in the conversation). Each update is shown, and read aloud unless Voice is \(SpokenVoiceRows.textOnlyLabel). Replies to dictation are skipped while you\u{2019}re viewing the conversation. A short reply is given as it is; a longer one is summarized by the AI service you choose, or announced without one. You also get an update when the agent needs approval or disconnects before finishing. When \(Branding.appName) can\u{2019}t confirm the conversation is in front, it gives the update."

    var body: some View {
        Section("Replies") {
            SettingRow(
                title: "Reply updates",
                result: model.spokenResult.enabled ? currentSummary : "Get replies to messages you dictate or ask the agent to report, and know when it needs you.",
                help: Self.help)
            {
                Toggle("", isOn: enabled)
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenResultEnabled)
            }
            if model.spokenResult.enabled {
                DisclosureSection(
                    isExpanded: $optionsExpanded, hasError: missing || model.voice?.status == .needsAttention,
                    headerID: AccessibilityID.Mode.Agents.replyOptions
                ) {
                    DisclosureSummaryLabel(title: "More reply options", summary: "Summary service, voice, summary instruction, and voice files")
                } content: {
                    serviceRows
                    if let voice = model.voice {
                        SpokenVoiceRows(
                            voice: voice, selection: $model.voiceChoice, spokenVoice: model.chosenVoice,
                            sharedNote: "This choice also applies to Ask modes\u{2019} answers.")
                    }
                    Divider()
                    PromptEditor(
                        title: "Summary instruction",
                        placeholder: "How the AI should sum up a reply\u{2026}",
                        text: model.spokenResult.effectivePrompt,
                        expandID: AccessibilityID.Mode.Agents.spokenResultPromptExpand,
                        expandDoneID: AccessibilityID.Mode.Agents.spokenResultPromptExpandDone
                    ) { value in
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.spokenResult.prompt = trimmed.isEmpty || trimmed == SpokenResultSettings.defaultPrompt ? nil : value
                    }
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenResultPrompt)
                    HStack {
                        Spacer()
                        Button("Reset to Default") { model.spokenResult.prompt = nil }
                            .disabled(model.spokenResult.prompt == nil)
                            .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenResultReset)
                    }
                    if let voice = model.voice {
                        SpokenVoiceFiles(voice: voice)
                    }
                }
            }
        }
    }

    private var currentSummary: String {
        let voice = model.spokenResult.textOnly
            ? "Shown as text, not read aloud."
            : "Read aloud with the \(SpokenVoices.all.first { $0.id == model.chosenVoice }?.name ?? "chosen") voice."
        let summary = chosen.map { "Longer replies are summarized by \($0.name)." } ?? "Longer replies are announced without a summary."
        return "\(voice) \(summary)"
    }

    @ViewBuilder private var serviceRows: some View {
        if connections.isEmpty {
            IssueText("Add an AI service to hear summaries of longer replies and what a waiting prompt asks. Without one, a longer reply is announced without a summary.", severity: .advisory)
            HStack {
                Button("Open AI Services") { model.onOpenAIServices?() }
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenResultOpenAIServices)
                Spacer()
            }
        } else {
            SettingRow(title: "Summary service", result: boundary, help: serviceHelp) {
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
                .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenResultService)
            }
            if missing {
                IssueText("That AI service no longer exists. Choose another.")
            }
        }
    }

    private var boundary: String? {
        guard let chosen else { return missing ? nil : "Longer replies are announced without a summary. Nothing is sent." }
        return "Long replies and waiting prompts go to \(chosen.name) after best-effort redaction."
    }

    private var serviceHelp: String {
        let name = chosen?.name ?? "the chosen service"
        return "A longer reply is sent to \(name) to be summarized. When a conversation waits on a prompt its connector describes, the prompt\u{2019}s title, the tool call it seems to be about (such as a command to approve) and the agent\u{2019}s last words are sent to say what it asks. Both go after best-effort redaction, which can miss things in code and command output. A short reply is read as it is, without any service; with None, a longer reply is announced without a summary. With History on, \(Branding.appName) saves what was read aloud in History."
    }

    private var chosen: Connection? { connections.first { $0.id == model.spokenResult.connection } }
    private var missing: Bool { chosen == nil && !model.spokenResult.connection.isEmpty }

    private var enabled: Binding<Bool> {
        Binding(get: { model.spokenResult.enabled }, set: { model.spokenResult.enabled = $0 })
    }

    private var service: Binding<String> {
        Binding(get: { model.spokenResult.connection }, set: { model.spokenResult.connection = $0 })
    }

}

struct SpokenVoiceRows: View {
    @ObservedObject var voice: SpokenVoiceModel
    let selection: Binding<String>
    let spokenVoice: String
    let sharedNote: String
    @State private var preview: NaturalSpeech?

    private static let help = "Speech is made on this Mac; what it reads is never sent anywhere. With Off \u{2014} text only, results are shown without being read aloud."
    static let textOnlyLabel = "Off \u{2014} text only"
    private var size: String { ByteCountFormatter.fileStyle.string(fromByteCount: SpokenVoiceModel.approxDownloadBytes) }
    private var textOnly: Bool { selection.wrappedValue == AgentsSettingsModel.textOnlyChoice }

    var body: some View {
        voiceRow
        Text(sharedNote)
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenResultVoiceShared)
        if textOnly {
            EmptyView()
        } else if let error = voice.error {
            IssueText(error, severity: voice.status == .needsAttention ? .failure : .advisory)
        } else if voice.status == .ready, let reason = voice.fallbackReason {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                IssueText("The macOS voice read the last spoken update because \(reason).", severity: .advisory)
                if let entry = voice.fallbackEntry, let show = voice.showEntry {
                    Button("Show in History") { show(entry) }
                        .buttonStyle(.link)
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenVoiceShowInHistory)
                }
            }
        }
        if !textOnly, voice.status == .ready, let reason = voice.previewFallbackReason {
            IssueText("The preview used the macOS voice because \(reason).", severity: .advisory)
        }
    }

    @ViewBuilder private var voiceRow: some View {
        switch voice.status {
        case .ready:
            SettingRow(title: "Voice", help: Self.help, combinesAccessibilityChildren: false) {
                wrapping {
                    picker
                    if !textOnly { previewButton }
                }
            }
        case .notInstalled:
            SettingRow(
                title: "Voice",
                result: textOnly ? nil : "Using the macOS voice. Download the natural voice for better speech.",
                help: Self.help, combinesAccessibilityChildren: false)
            {
                wrapping {
                    picker
                    if !textOnly { previewButton }
                    Button("Download English \u{00B7} \(size)") { voice.download() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Download the English voice, \(size)")
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenVoiceDownload)
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
                wrapping {
                    picker
                    Button("Reinstall voice") { voice.reinstall() }
                        .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenVoiceReinstall)
                }
            }
        }
    }

    private var picker: some View {
        Picker("Voice", selection: selection) {
            Text(Self.textOnlyLabel).tag(AgentsSettingsModel.textOnlyChoice)
            Divider()
            ForEach(SpokenVoices.all) { option in
                Text(option.label).tag(option.id)
            }
        }
        .labelsHidden()
        .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenResultVoice)
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
            .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenResultPreview)
    }

    private func playPreview() {
        let speech = preview ?? makePreview()
        preview = speech
        SpeechSilencer.shared.speak(SpokenVoices.sample, voice: spokenVoice, with: speech)
    }

    private func makePreview() -> NaturalSpeech {
        let speech = SpeechSilencer.shared.registered(voice.makeSpeech(preview: true))
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
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenVoiceDelete)
            }
            .confirmationDialog(
                "Delete the voice?",
                isPresented: Binding(get: { voice.pendingDelete }, set: { if !$0 { voice.cancelDelete() } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { voice.confirmDelete() }
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenVoiceDeleteConfirm)
                Button("Cancel", role: .cancel) { voice.cancelDelete() }
                    .accessibilityIdentifier(AccessibilityID.Mode.Agents.spokenVoiceDeleteCancel)
            } message: {
                Text("Replies are read in the macOS voice until you download it again.")
            }
        }
    }
}
