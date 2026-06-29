import SwiftUI
import KeyScribeKit

struct FirstRunView: View {
    @ObservedObject var model: FirstRunModel
    @FocusState private var trialFieldFocused: Bool
    @State private var modelChoiceExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch model.step {
            case .intro: intro
            case .model: modelStep
            case .permissions: permissions
            case .tryIt: tryIt
            case .aiService: aiService
            case .aiServiceComplete: aiServiceComplete
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.step) { _, step in
            if step == .permissions { model.startPolling() } else { model.stopPolling() }
            if step == .tryIt { trialFieldFocused = true }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Welcome to \(Branding.appName)").font(.largeTitle.bold())
            Text("\(Branding.appName) turns your voice into text, entirely on this Mac. Speech recognition never leaves it.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") { model.step = .model }
                .keyboardShortcut(.defaultAction).controlSize(.large)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download speech recognition").font(.title.bold())
            Text("\(Branding.appName) needs one on-device recognizer before it can turn speech into text. Start with the recommended option; it is a good balance of accuracy, speed, and size.")
                .foregroundStyle(.secondary)
            modelCard
            DisclosureSection("Advanced: choose a different recognizer", isExpanded: $modelChoiceExpanded) {
                Text("Different recognizers trade accuracy, language support, download size, and startup time. You can change this later in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Model", selection: $model.selectedEngineId) {
                    ForEach(downloadableModels) { info in
                        Text(modelChoiceLabel(info)).tag(info.id)
                    }
                }
                .labelsHidden()
            }
            if model.downloading {
                ProgressView(value: model.downloadProgress) {
                    Text("Downloading… \(Int(model.downloadProgress * 100))%")
                }
            }
            if let error = model.downloadError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Spacer()
            HStack {
                if model.appleSpeechAvailable {
                    Button("Use Apple Speech") { model.skipModelDownload() }
                        .buttonStyle(.link)
                        .disabled(model.downloading)
                }
                Spacer()
                Button(model.downloading ? "Downloading…" : modelDownloadButtonTitle) {
                    model.beginDownload()
                }
                .keyboardShortcut(.defaultAction).controlSize(.large)
                .disabled(model.downloading)
            }
            Text("Apple Speech is built into macOS and needs no download. It works as a fallback, but the recommended recognizer is usually more accurate.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var modelCard: some View {
        let info = model.selectedInfo
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: info?.kind == .apple ? "apple.logo" : "waveform")
                .font(.title2).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(info?.displayName ?? "Speech model").font(.headline)
                    if info?.isDefaultEnglish == true {
                        Text("Recommended").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule()).foregroundStyle(.tint)
                    }
                }
                Text(modelMeta(info)).font(.caption).foregroundStyle(.secondary)
                Text("Downloaded once and used locally for every dictation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var modelDownloadButtonTitle: String {
        guard let info = model.selectedInfo else { return "Download Recognizer" }
        return info.isDefaultEnglish ? "Download Recommended Recognizer" : "Download \(info.displayName)"
    }

    private var downloadableModels: [SpeechModelInfo] {
        model.catalog.filter { !$0.systemManaged }
    }

    private func modelChoiceLabel(_ info: SpeechModelInfo) -> String {
        let prefix = info.isDefaultEnglish ? "Recommended: " : ""
        return "\(prefix)\(info.displayName) — \(info.summary)"
    }

    private func modelMeta(_ info: SpeechModelInfo?) -> String {
        guard let info else { return "" }
        let lang = info.languageCount <= 1 ? "English" : "\(info.languageCount) languages"
        let size = info.systemManaged
            ? "system-managed"
            : "~\(ByteCountFormatter.string(fromByteCount: info.approxDownloadBytes, countStyle: .file))"
        return "\(lang) · \(size) · stays on this Mac"
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up dictation").font(.title.bold())
            Text("\(Branding.appName) asks for one permission at a time, only when the next part of dictation needs it.")
                .foregroundStyle(.secondary)

            permissionStep

            Spacer()
            if model.needsRelaunch {
                Text("Accessibility is granted, but it only takes effect after a relaunch. Quit & Relaunch to finish setup.")
                    .font(.caption).foregroundStyle(.orange)
            } else if !model.allPermissionsGranted {
                Text(model.permissionsOnly
                    ? "Grant each one (the toggle opens in System Settings), then Quit & Relaunch to Apply — Accessibility only takes effect after the relaunch."
                    : "You can skip and finish setup now, then grant any remaining permissions later in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Skip for now") { model.finish() }
                    .buttonStyle(.link)
                Spacer()
                if model.permissionsOnly {
                    if model.allPermissionsGranted {
                        Button("Done") { model.finish() }
                            .keyboardShortcut(.defaultAction).controlSize(.large)
                    } else {
                        Button("Quit & Relaunch to Apply") { model.relaunch() }
                            .keyboardShortcut(.defaultAction).controlSize(.large)
                    }
                } else if model.needsRelaunch {
                    Button("Quit & Relaunch to Apply") { model.relaunch() }
                        .keyboardShortcut(.defaultAction).controlSize(.large)
                } else {
                    Button("Continue") { model.continueFromPermissions() }
                        .keyboardShortcut(.defaultAction).controlSize(.large)
                        .disabled(!model.allPermissionsGranted)
                }
            }
        }
    }

    @ViewBuilder private var permissionStep: some View {
        switch model.nextPermission {
        case .microphone:
            permissionRow("Microphone", "So \(Branding.appName) can hear you.",
                          "Dictation cannot start without it.", model.micStatus,
                          openSettings: { model.openMicrophoneSettings() }) { model.requestMicrophone() }
        case .accessibility:
            permissionRow("Accessibility", "So finished text can be pasted into the focused field.",
                          "Dictation can be transcribed, but it will be copied instead of inserted.", model.axStatus,
                          openSettings: { model.openAccessibilitySettings() }) {
                model.requestAccessibility()
            }
        }
    }

    private func permissionRow(_ title: String, _ detail: String, _ unavailable: String, _ status: PermissionStatus,
                               openSettings: @escaping () -> Void, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(status)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                if status != .granted {
                    Text(unavailable).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status != .granted {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Grant", action: action)
                    Button("Open System Settings", action: openSettings)
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private func statusIcon(_ status: PermissionStatus) -> some View {
        Image(systemName: status == .granted ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(status == .granted ? .green : .secondary)
            .font(.title3)
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try it now").font(.title.bold())
            Text("Hold the **Fn (Globe)** key, say a sentence, and release. Your words appear wherever the cursor is.")
                .foregroundStyle(.secondary)
            Text("Dictate into this box to finish setup:").font(.callout)
            TextEditor(text: $model.trialText)
                .font(.body)
                .ghostText("Your dictated words will appear here\u{2026}", visible: model.trialText.isEmpty)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .focused($trialFieldFocused)
            if model.trialSucceeded {
                Label("Dictation worked — you're set up.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            } else {
                Label("Continue unlocks after one successful dictation lands here.", systemImage: "mic")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Skip for now") { model.finish() }
                    .buttonStyle(.link)
                Spacer()
                Button("Continue") { model.step = .aiService }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
                    .disabled(!model.trialSucceeded)
            }
        }
    }

    private var aiService: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional text cleanup").font(.title.bold())
            Text("Connect an AI service for rewrite modes. Speech stays local.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Label("Hosted providers use API keys. Local OpenAI-compatible endpoints can use no auth or a token command.", systemImage: "key")
                if !model.aiModeNames.isEmpty {
                    Label("\(Branding.appName) will connect \(formattedModeNames(model.aiModeNames)) to this service.", systemImage: "wand.and.stars")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            aiServiceFields

            if let error = model.aiModelDiscoveryError {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            if let error = model.aiSetupError {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            Spacer()
            HStack {
                Button("Set Up Later") { model.finish() }
                    .buttonStyle(.link)
                    .disabled(model.aiTesting)
                Spacer()
                if model.aiTesting { ProgressView().controlSize(.small) }
                Button(model.aiTesting ? "Testing…" : "Connect AI Service") {
                    Task { await model.createAIService() }
                }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
                    .disabled(!model.aiCanConnect || model.aiTesting)
            }
        }
        .onChange(of: model.aiProvider) { oldProvider, provider in
            if model.aiServiceName == oldProvider.defaultName {
                model.aiServiceName = provider.defaultName
            }
            model.aiModel = provider.defaultModel
            if provider == .openaiCompatible {
                if model.aiAuthMethod == .apiKey,
                   model.aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    model.aiAuthMethod = .none
                }
            } else if model.aiAuthMethod == .none {
                model.aiAuthMethod = .apiKey
            }
            model.resetAIModelDiscovery()
        }
    }

    private var aiServiceFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            aiTextRow("Name", text: $model.aiServiceName)
            aiThinDivider
            HStack {
                Text("Provider")
                Spacer()
                Picker("", selection: $model.aiProvider) {
                    Text("OpenAI").tag(Connection.Provider.openai)
                    Text("Anthropic").tag(Connection.Provider.anthropic)
                    Text("Gemini").tag(Connection.Provider.gemini)
                    Text("OpenAI-compatible").tag(Connection.Provider.openaiCompatible)
                }
                .labelsHidden()
                .frame(maxWidth: 230, alignment: .trailing)
            }
            if model.aiProvider == .openaiCompatible {
                aiThinDivider
                VStack(alignment: .leading, spacing: 4) {
                    aiTextRow("Base URL", text: $model.aiBaseURL)
                    Text("Example: http://127.0.0.1:11234/v1")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        aiRequiredLabel("Base URL is required.")
                    }
                }
            }
            aiThinDivider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Credential")
                    Spacer()
                    Picker("Credential", selection: aiCredentialBinding) {
                        if model.aiProvider == .openaiCompatible {
                            Text("No Auth").tag(Connection.AuthMethod.none)
                        }
                        Text("API Key").tag(Connection.AuthMethod.apiKey)
                        Text("Command").tag(Connection.AuthMethod.tokenCommand)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: model.aiProvider == .openaiCompatible ? 310 : 220)
                }
                aiCredentialFields
            }
            aiThinDivider
            aiModelFields
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func aiTextRow(_ title: String, text: Binding<String>, prompt: String? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", text: text, prompt: prompt.map(Text.init))
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .frame(maxWidth: 260)
        }
    }

    private var aiThinDivider: some View {
        Divider().padding(.vertical, 6)
    }

    private var aiCredentialBinding: Binding<Connection.AuthMethod> {
        Binding(
            get: { model.aiEffectiveAuthMethod },
            set: { value in
                let next = (model.aiProvider != .openaiCompatible && value == .none) ? .apiKey : value
                model.aiAuthMethod = next
                model.resetAIModelDiscovery()
            })
    }

    @ViewBuilder private var aiCredentialFields: some View {
        switch aiCredentialBinding.wrappedValue {
        case .none:
            Label("No Authorization header", systemImage: "globe")
                .font(.caption).foregroundStyle(.secondary)
        case .apiKey:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("API key")
                    Spacer()
                    SecureField("API key", text: $model.aiAPIKey)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: 260)
                }
                if model.aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    aiRequiredLabel("Enter an API key before connecting.")
                }
                Label("Saved to Keychain when you connect", systemImage: "key")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .tokenCommand:
            VStack(alignment: .leading, spacing: 4) {
                aiTextRow(
                    "Command", text: $model.aiTokenCommand,
                    prompt: "e.g. print-token")
                if model.aiTokenCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    aiRequiredLabel("Enter the command that prints a fresh token or key.")
                }
                Text("stdout: raw token or JSON token fields.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var aiModelFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            aiTextRow("Model ID", text: $model.aiModel)
            if model.aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                aiRequiredLabel("Model ID is required.")
            }
            HStack {
                Button(model.aiFetchingModels ? "Fetching Models" : "Fetch Models") {
                    Task { await model.fetchAIModels() }
                }
                .disabled(model.aiFetchingModels || !model.aiCanFetchModels)
                if model.aiFetchingModels { ProgressView().controlSize(.small) }
                Spacer()
                if !model.aiAvailableModels.isEmpty {
                    Text("\(model.aiAvailableModels.count) found")
                        .font(.caption).foregroundStyle(.secondary)
                    Menu("Choose") {
                        ForEach(model.aiAvailableModels, id: \.self) { id in
                            Button(id) { model.aiModel = id }
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            if let reason = model.aiModelFetchDisabledReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func aiRequiredLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.caption).foregroundStyle(.orange)
    }

    private var aiServiceComplete: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("AI cleanup is connected").font(.title.bold())
            Text("\(model.aiServiceName) is ready to clean up dictation, draft messages, and work on selected text in rewrite modes.")
                .foregroundStyle(.secondary)
            switch model.aiAuthMethod {
            case .none:
                Label("No Authorization header is used for this service.", systemImage: "globe")
                    .font(.caption).foregroundStyle(.secondary)
            case .apiKey:
                Label("Your API key is stored in Keychain.", systemImage: "key")
                    .font(.caption).foregroundStyle(.secondary)
            case .tokenCommand:
                Label("Token command saved. Generated tokens are kept in memory only.", systemImage: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done") { model.finish() }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
    }

    private func formattedModeNames(_ names: [String]) -> String {
        switch names.count {
        case 0:
            return "the starter rewrite modes"
        case 1:
            return names[0]
        case 2:
            return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + ", and \(names.last ?? "")"
        }
    }
}
