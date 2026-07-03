import AppKit
import SwiftUI
import KeyScribeKit

struct FirstRunView: View {
    @ObservedObject var model: FirstRunModel
    @FocusState private var trialFieldFocused: Bool
    @FocusState private var playgroundFieldFocused: Bool
    @State private var modelChoiceExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch model.step {
            case .intro: intro
            case .model: modelStep
            case .permissions: permissions
            case .tryIt: tryIt
            case .aiService: aiService
            case .playground: playground
            }
        }
        .padding(28)
        .frame(width: 480, height: 500, alignment: .topLeading)
        .onChange(of: model.step) { _, step in
            if step == .permissions { model.startPolling() } else { model.stopPolling() }
            if step == .tryIt { trialFieldFocused = true }
            if step == .playground { playgroundFieldFocused = true }
        }
        .onChange(of: model.activePlaygroundLessonId) { _, _ in
            guard model.step == .playground else { return }
            focusPlaygroundText(selectAll: false)
        }
        .onChange(of: model.playgroundReseedToken) { _, _ in
            guard model.step == .playground else { return }
            focusPlaygroundText(selectAll: true)
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
            : "~\(ByteCountFormatter.fileStyle.string(fromByteCount: info.approxDownloadBytes))"
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
                Button("Done") { model.finish() }
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
                Label("\(Branding.appName) will connect the starter rewrite modes to this service.", systemImage: "wand.and.stars")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            AIConnectionDraftEditor(
                presentation: .onboarding,
                draft: $model.aiDraft,
                hasStoredKey: false,
                testState: model.aiTesting ? .testing : nil,
                onCommit: { _, _ in },
                onFetchModels: { _ in Task { await model.fetchAIModels() } })

            if let error = model.aiSetupError {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            Spacer()
            HStack {
                Button("Set Up Later") { model.skipAISetup() }
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
    }

    private var playground: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try it now").font(.title.bold())
            Text("Start with normal dictation. Then try the rewrite modes you just enabled. You can leave anytime.")
                .foregroundStyle(.secondary)
            TextEditor(text: $model.playgroundText)
                .font(.body)
                .ghostText(playgroundPlaceholder, visible: model.playgroundText.isEmpty)
                .frame(height: 76)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .focused($playgroundFieldFocused)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.playgroundLessons) { lesson in
                    lessonAccordion(lesson)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { model.finish() }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
    }

    private var playgroundPlaceholder: String {
        switch model.activePlaygroundLessonId {
        case Mode.directId:
            return "Hold Fn (Globe), say one sentence, and release\u{2026}"
        case .some(let id) where id.contains("edit-selection"):
            return "Select this text with Command-A, then say \"make this shorter\"\u{2026}"
        default:
            return "Dictate or paste a rough sentence to polish\u{2026}"
        }
    }

    private func lessonAccordion(_ lesson: FirstRunModel.PlaygroundLesson) -> some View {
        let outcome = model.completedLessons[lesson.modeId]
        let finished = model.finishedPlaygroundLessonIds.contains(lesson.modeId)
        let expanded = model.activePlaygroundLessonId == lesson.modeId
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                model.openPlaygroundLesson(lesson.modeId)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: finished ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(finished ? .green : .secondary)
                        .font(.title3)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lesson.title).font(.headline)
                        Text(lesson.invocation).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                Divider().padding(.leading, 32)
                if let outcome {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You said: \(outcome.before)").font(.caption).foregroundStyle(.secondary)
                        Text(outcome.after).font(.callout)
                    }
                    .padding(.leading, 32)
                } else {
                    Text(lesson.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 32)
                }
                if finished && outcome == nil {
                    Label("Marked complete", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.leading, 32)
                }
                if !model.isLastPlaygroundLesson(lesson.modeId) {
                    HStack {
                        Spacer()
                        Button("Next") { model.advancePlayground() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: expanded ? .controlBackgroundColor : .textBackgroundColor).opacity(expanded ? 0.9 : 0.45)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private func focusPlaygroundText(selectAll: Bool) {
        playgroundFieldFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            playgroundFieldFocused = true
            guard selectAll else { return }
            if let textView = findPlaygroundTextView(in: NSApp.keyWindow?.contentView) {
                textView.selectAll(nil)
            } else {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private func findPlaygroundTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView, textView.string == model.playgroundText {
            return textView
        }
        for subview in view.subviews {
            if let textView = findPlaygroundTextView(in: subview) {
                return textView
            }
        }
        return nil
    }
}
