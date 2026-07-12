import AppKit
import SwiftUI
import KeyScribeKit

struct FirstRunView: View {
    @ObservedObject var model: FirstRunModel
    @FocusState private var trialFieldFocused: Bool
    @FocusState private var playgroundFieldFocused: Bool
    @State private var modelChoiceExpanded = false
    @State private var changeTriggerRevealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            stepContent
                .id(model.step)
                .transition(reduceMotion ? .identity : .opacity)
        }
        .frame(width: 480, height: 500, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if !model.permissionsOnly { stepDots }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.step)
        .onChange(of: model.step) { _, step in
            if step == .permissions { model.startPolling() } else { model.stopPolling() }
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

    @ViewBuilder private var stepContent: some View {
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
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<FirstRunModel.stepCount, id: \.self) { index in
                Circle()
                    .fill(index <= model.stepIndex ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.bottom, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(model.stepIndex + 1) of \(FirstRunModel.stepCount)")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative.reversing, options: .repeat(.continuous), isActive: !reduceMotion)
            Text("Welcome to \(Branding.appName)").font(.largeTitle.bold())
            Text("Your voice becomes text — entirely on this Mac.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") { model.step = .model }
                .keyboardShortcut(.defaultAction).controlSize(.large)
                .accessibilityIdentifier(AccessibilityID.FirstRun.Intro.getStarted)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose speech recognition").font(.title.bold())
            Text("Download one model for fast, accurate dictation. It stays on this Mac.")
                .foregroundStyle(.secondary)
            modelCard
            DisclosureSection("Choose another model", isExpanded: $modelChoiceExpanded) {
                Text("Compare accuracy, language support, download size, and startup time. You can change this later in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Model", selection: $model.selectedEngineId) {
                    ForEach(downloadableModels) { info in
                        Text(modelChoiceLabel(info)).tag(info.id)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier(AccessibilityID.FirstRun.Model.enginePicker)
            }
            .accessibilityIdentifier(AccessibilityID.FirstRun.Model.advancedDisclosure)
            if model.downloading {
                ProgressView(value: model.downloadProgress) {
                    Text("Downloading… \(Int(model.downloadProgress * 100))%")
                }
                .accessibilityIdentifier(AccessibilityID.FirstRun.Model.progress)
            }
            if let error = model.downloadError {
                IssueText(error, font: .callout)
            }
            Spacer()
            HStack {
                if model.appleSpeechAvailable {
                    Button("Use built-in speech") { model.skipModelDownload() }
                        .buttonStyle(.link)
                        .disabled(model.downloading)
                        .accessibilityIdentifier(AccessibilityID.FirstRun.Model.useAppleSpeech)
                }
                Spacer()
                Button(model.downloading ? "Downloading…" : modelDownloadButtonTitle) {
                    model.beginDownload()
                }
                .keyboardShortcut(.defaultAction).controlSize(.large)
                .disabled(model.downloading)
                .accessibilityIdentifier(AccessibilityID.FirstRun.Model.download)
            }
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
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
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
            Text("One permission at a time, each asked when dictation needs it.")
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
                    .accessibilityIdentifier(AccessibilityID.FirstRun.Permissions.skip)
                Spacer()
                if model.permissionsOnly {
                    if model.allPermissionsGranted {
                        Button("Done") { model.finish() }
                            .keyboardShortcut(.defaultAction).controlSize(.large)
                            .accessibilityIdentifier(AccessibilityID.FirstRun.Permissions.done)
                    } else {
                        Button("Quit & Relaunch to Apply") { model.relaunch() }
                            .keyboardShortcut(.defaultAction).controlSize(.large)
                            .accessibilityIdentifier(AccessibilityID.FirstRun.Permissions.relaunch)
                    }
                } else if model.needsRelaunch {
                    Button("Quit & Relaunch to Apply") { model.relaunch() }
                        .keyboardShortcut(.defaultAction).controlSize(.large)
                        .accessibilityIdentifier(AccessibilityID.FirstRun.Permissions.relaunch)
                } else {
                    Button("Continue") { model.continueFromPermissions() }
                        .keyboardShortcut(.defaultAction).controlSize(.large)
                        .disabled(!model.allPermissionsGranted)
                        .accessibilityIdentifier(AccessibilityID.FirstRun.Permissions.continue)
                }
            }
        }
    }

    @ViewBuilder private var permissionStep: some View {
        switch model.nextPermission {
        case .microphone:
            permissionRow("microphone", "Microphone", "So \(Branding.appName) can hear you.",
                          "Dictation cannot start without it.", model.micStatus,
                          openSettings: { model.openMicrophoneSettings() }) { model.requestMicrophone() }
        case .accessibility:
            permissionRow("accessibility", "Accessibility", "So finished text can be pasted into the focused field.",
                          "Dictation can be transcribed, but it will be copied instead of inserted.", model.axStatus,
                          openSettings: { model.openAccessibilitySettings() }) {
                model.requestAccessibility()
            }
        }
    }

    private func permissionRow(_ permID: String, _ title: String, _ detail: String, _ unavailable: String, _ status: PermissionStatus,
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
                        .accessibilityIdentifier(AccessibilityID.FirstRun.Permissions.grant(permID))
                    Button("Open System Settings", action: openSettings)
                        .buttonStyle(.link).font(.caption)
                        .accessibilityIdentifier(AccessibilityID.FirstRun.Permissions.openSettings(permID))
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.FirstRun.Permissions.row(permID))
    }

    private func statusIcon(_ status: PermissionStatus) -> some View {
        Image(systemName: status == .granted ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(status == .granted ? .green : .secondary)
            .font(.title3)
    }

    private var triggerWellVisible: Bool { changeTriggerRevealed || model.directTrigger == nil }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try your voice").font(.title.bold())
            if let descriptor = model.directTrigger {
                HStack(spacing: 6) {
                    KeycapView(descriptor: descriptor)
                    Text((PressStyle(rawValue: model.directTriggerStyle ?? "hold-or-tap") ?? .holdOrTap).instruction)
                        .foregroundStyle(.secondary)
                }
                Text("Your words appear in any app.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Choose a key to hold while you speak.")
                    .foregroundStyle(.secondary)
            }
            if triggerWellVisible {
                Text("Dictation key").font(.callout)
                ShortcutWell(
                    key: model.directTriggerBinding, profile: .modeTrigger,
                    accessibilityID: AccessibilityID.FirstRun.TryIt.shortcutWell)
                if let error = model.triggerSaveError {
                    IssueText(error)
                }
            } else {
                Button("Use a different key…") { changeTriggerRevealed = true }
                    .buttonStyle(.link)
                    .accessibilityIdentifier(AccessibilityID.FirstRun.TryIt.changeTrigger)
            }
            Text("Say anything:").font(.callout)
            TextEditor(text: $model.trialText)
                .font(.body)
                .ghostText("Your words will appear here\u{2026}", visible: model.trialText.isEmpty)
                .frame(height: 96)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .focused($trialFieldFocused)
                .accessibilityIdentifier(AccessibilityID.FirstRun.TryIt.field)
            if model.trialSucceeded {
                Label("That worked. You're ready to dictate anywhere.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            } else {
                Label("Say anything to continue, or skip for now.", systemImage: "mic")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Skip for now") { model.continueFromTrial() }
                    .buttonStyle(.link)
                    .accessibilityIdentifier(AccessibilityID.FirstRun.TryIt.skip)
                Spacer()
                Button("Continue") { model.continueFromTrial() }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
                    .disabled(!model.trialSucceeded)
                    .accessibilityIdentifier(AccessibilityID.FirstRun.TryIt.done)
            }
        }
        // Focus here, not in the parent's `.onChange(of: model.step)`: `.id(model.step)` recreates this
        // subtree on the cross-fade, so the fresh TextEditor exists only once this content appears.
        .onAppear(perform: focusTrialField)
    }


    private var aiService: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Make rough dictation clear").font(.title.bold())
            Text("Optional — add your AI service to turn rough words into polished text. Speech recognition stays on this Mac.")
                .font(.callout).foregroundStyle(.secondary)

            if model.aiOfferExpanded {
                AIConnectionDraftEditor(
                    presentation: .onboarding,
                    draft: $model.aiDraft,
                    hasStoredKey: false,
                    testState: model.aiTesting ? .testing : nil,
                    onCommit: { _, _ in },
                    onFetchModels: { _ in Task { await model.fetchAIModels() } })
                    .accessibilityIdentifier(AccessibilityID.FirstRun.AI.connectionEditor)

                if let error = model.aiSetupError {
                    IssueText(error, font: .callout)
                }

                Spacer()
                HStack {
                    Button("Finish without AI") { model.finishWithoutAI() }
                        .buttonStyle(.link)
                        .disabled(model.aiTesting)
                        .accessibilityIdentifier(AccessibilityID.FirstRun.AI.skip)
                    Spacer()
                    if model.aiTesting { ProgressView().controlSize(.small) }
                    Button(model.aiTesting ? "Testing…" : "Connect and try cleanup") {
                        model.connect()
                    }
                        .keyboardShortcut(.defaultAction).controlSize(.large)
                        .disabled(!model.aiCanConnect || model.aiTesting)
                        .accessibilityIdentifier(AccessibilityID.FirstRun.AI.connect)
                }
            } else {
                aiPreview
                Spacer()
                HStack {
                    Button("Finish") { model.finish() }
                        .buttonStyle(.link)
                        .accessibilityIdentifier(AccessibilityID.FirstRun.AI.skip)
                    Spacer()
                    Button("Add AI cleanup…") { model.aiOfferExpanded = true }
                        .keyboardShortcut(.defaultAction).controlSize(.large)
                        .accessibilityIdentifier(AccessibilityID.FirstRun.AI.offerConnect)
                }
            }
        }
    }

    private var playground: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Make your words sharper").font(.title.bold())
            Text("Your service is connected. Try these two everyday edits:")
                .foregroundStyle(.secondary)
            TextEditor(text: $model.playgroundText)
                .font(.body)
                .ghostText(playgroundPlaceholder, visible: model.playgroundText.isEmpty)
                .frame(height: 76)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .focused($playgroundFieldFocused)
                .accessibilityIdentifier(AccessibilityID.FirstRun.Playground.field)
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
                    .accessibilityIdentifier(AccessibilityID.FirstRun.Playground.done)
            }
        }
        .onAppear { focusPlaygroundText(selectAll: false) }
    }

    private var playgroundPlaceholder: String {
        if let id = model.activePlaygroundLessonId, id.contains("edit-selection") {
            return "Select this text with Command-A, then say \"make this shorter\"\u{2026}"
        }
        return "Say or paste something rough to polish\u{2026}"
    }

    private var aiPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ROUGH")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            Text(FirstRunModel.polishExample)
                .font(.caption).foregroundStyle(.secondary)
            Text("POLISHED")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tint)
            Text(FirstRunModel.polishExamplePolished)
                .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func lessonInvocation(_ lesson: FirstRunModel.PlaygroundLesson) -> some View {
        if let key = lesson.triggerKey, let descriptor = try? KeyDescriptor(parsing: key),
           !descriptor.keycapTokens.isEmpty {
            HStack(spacing: 4) {
                Text("Hold").font(.caption).foregroundStyle(.secondary)
                KeycapView(descriptor: descriptor)
                Text("and speak").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text(lesson.invocation).font(.caption).foregroundStyle(.secondary)
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
                        lessonInvocation(lesson)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.FirstRun.Playground.lesson(lesson.modeId))
            if expanded {
                Divider().padding(.leading, 32)
                if let outcome {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Before: \(outcome.before)").font(.caption).foregroundStyle(.secondary)
                        Text("After: \(outcome.after)").font(.callout)
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
                        Button("Next demo") { model.advancePlayground() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier(AccessibilityID.FirstRun.Playground.next)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(expanded ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private func focusTrialField() {
        trialFieldFocused = true
        // Re-assert after the subtree settles: the incoming `.onAppear` can fire a hair before the recreated
        // TextEditor is ready to accept focus (same timing the playground field guards against).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { trialFieldFocused = true }
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
