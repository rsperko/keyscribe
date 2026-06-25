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
        .frame(width: 480, height: 500, alignment: .topLeading)
        .onChange(of: model.step) { _, step in
            if step == .permissions { model.startPolling() } else { model.stopPolling() }
            if step == .tryIt { trialFieldFocused = true }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Welcome to KeyScribe").font(.largeTitle.bold())
            Text("KeyScribe turns your voice into text, entirely on this Mac. Speech recognition never leaves it.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") { model.step = .model }
                .keyboardShortcut(.defaultAction).controlSize(.large)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download speech recognition").font(.title.bold())
            Text("KeyScribe needs one on-device recognizer before it can turn speech into text. Start with the recommended option; it is a good balance of accuracy, speed, and size.")
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
                Button("Use Apple Speech") { model.skipModelDownload() }
                    .buttonStyle(.link)
                    .disabled(model.downloading)
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
            Text("KeyScribe asks for one permission at a time, only when the next part of dictation needs it.")
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
            permissionRow("Microphone", "So KeyScribe can hear you.",
                          "Dictation cannot start without it.", model.micStatus) { model.requestMicrophone() }
        case .accessibility:
            permissionRow("Accessibility", "So finished text can be pasted into the focused field.",
                          "Dictation can be transcribed, but it will be copied instead of inserted.", model.axStatus) {
                model.requestAccessibility()
            }
        }
    }

    private func permissionRow(_ title: String, _ detail: String, _ unavailable: String, _ status: PermissionStatus,
                               action: @escaping () -> Void) -> some View {
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
                Button("Grant", action: action)
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
                .font(.body).frame(height: 110)
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Optional text cleanup").font(.title.bold())
            Text("Connect an AI service if you want KeyScribe to clean up dictation, draft messages, or work on selected text. Speech recognition still stays on this Mac.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label("Only modes that use AI rewrite send text to this provider.", systemImage: "cloud")
                Label("Hosted providers need an API key. Local OpenAI-compatible endpoints can be keyless.", systemImage: "key")
                if !model.aiModeNames.isEmpty {
                    Label("KeyScribe will connect \(formattedModeNames(model.aiModeNames)) to this service.", systemImage: "wand.and.stars")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Form {
                TextField("Name", text: $model.aiServiceName)
                Picker("Provider", selection: $model.aiProvider) {
                    Text("OpenAI").tag(Connection.Provider.openai)
                    Text("Anthropic").tag(Connection.Provider.anthropic)
                    Text("Gemini").tag(Connection.Provider.gemini)
                    Text("OpenAI-compatible").tag(Connection.Provider.openaiCompatible)
                }
                if model.aiProvider == .openaiCompatible {
                    TextField("Base URL", text: $model.aiBaseURL)
                }
                SecureField("API key (optional for local endpoints)", text: $model.aiAPIKey)
                HStack {
                    TextField("Model", text: $model.aiModel)
                    if !model.aiAvailableModels.isEmpty {
                        Menu {
                            ForEach(model.aiAvailableModels, id: \.self) { id in
                                Button(id) { model.aiModel = id }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                        }
                        .menuStyle(.borderlessButton)
                    }
                    Button(model.aiFetchingModels ? "Fetching…" : "Fetch Models") {
                        Task { await model.fetchAIModels() }
                    }
                    .disabled(model.aiFetchingModels || !model.aiCanFetchModels)
                    if model.aiFetchingModels { ProgressView().controlSize(.small) }
                }
                Text("Fetch models to choose from the provider list, or type a model id manually.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

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
            // Only re-default the name while the user hasn't typed their own.
            if model.aiServiceName == oldProvider.defaultName {
                model.aiServiceName = provider.defaultName
            }
            model.aiModel = provider.defaultModel
            model.resetAIModelDiscovery()
        }
    }

    private var aiServiceComplete: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("AI cleanup is connected").font(.title.bold())
            Text("\(model.aiServiceName) is ready to clean up dictation, draft messages, and work on selected text in rewrite modes.")
                .foregroundStyle(.secondary)
            if model.aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("No API key was stored for this service.", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Your API key is stored in Keychain.", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
