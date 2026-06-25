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
            Text("Choose a speech model").font(.title.bold())
            Text("Speech recognition runs entirely on this Mac. The recommended model is a good default — you can change it anytime in Settings.")
                .foregroundStyle(.secondary)
            modelCard
            DisclosureSection("Choose another model", isExpanded: $modelChoiceExpanded) {
                Picker("Model", selection: $model.selectedEngineId) {
                    ForEach(model.catalog) { info in
                        Text(info.displayName + (info.isDefaultEnglish ? " (recommended)" : "")).tag(info.id)
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
                Button("Skip for now") { model.finish() }
                    .buttonStyle(.link)
                    .disabled(model.downloading)
                Spacer()
                Button(model.downloading ? "Downloading…" : "Download \(model.selectedInfo?.displayName ?? "model")") {
                    model.beginDownload()
                }
                .keyboardShortcut(.defaultAction).controlSize(.large)
                .disabled(model.downloading)
            }
            Text("Skipping finishes setup without a model — dictation can't transcribe until you download one in Settings.")
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
                Text("Stays on this Mac. Required before anything can be transcribed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func modelMeta(_ info: SpeechModelInfo?) -> String {
        guard let info else { return "" }
        let lang = info.languageCount <= 1 ? "English" : "\(info.languageCount) languages"
        let size = info.systemManaged
            ? "system-managed"
            : "~\(ByteCountFormatter.string(fromByteCount: info.approxDownloadBytes, countStyle: .file))"
        return "\(lang) · \(size) · on-device"
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up dictation").font(.title.bold())
            Text("KeyScribe asks for one permission at a time, only when the next part of dictation needs it.")
                .foregroundStyle(.secondary)

            permissionStep

            Spacer()
            if !model.allPermissionsGranted {
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
                } else {
                    Button("Continue") {
                        model.onReadyToDictate()
                        model.step = .tryIt
                    }
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
            Text("Connect your own AI service if you want KeyScribe to clean up dictation, draft messages, or work on selected text. Speech recognition still stays on this Mac.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label("Only modes that use AI rewrite send text to this provider.", systemImage: "cloud")
                Label("Your API key is stored in Keychain.", systemImage: "key")
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
                TextField("Model", text: $model.aiModel)
                if model.aiProvider == .openaiCompatible {
                    TextField("Base URL", text: $model.aiBaseURL)
                }
                SecureField(model.aiProvider == .openaiCompatible ? "API key (optional)" : "API key", text: $model.aiAPIKey)
            }
            .formStyle(.grouped)

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
