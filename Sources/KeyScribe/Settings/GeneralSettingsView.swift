import SwiftUI
import KeyScribeKit

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel
    var vocabularyShadowed = false
    var pasteLastShadowed = false
    var directMode: Mode?
    var onEditPlainDictation: () -> Void = {}

    private var directTrigger: Mode.TriggerKey? { directMode?.triggerKeys.first }
    private var directPressStyle: PressStyle {
        PressStyle(rawValue: directTrigger?.pressStyle ?? "") ?? .holdOrTap
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Shortcut") {
                    HStack(spacing: 10) {
                        if let directTrigger {
                            shortcutDisplay(directTrigger.key)
                            Text(directPressStyle.title)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("None")
                                .foregroundStyle(.secondary)
                        }
                        Button("Edit in Modes", action: onEditPlainDictation)
                            .accessibilityLabel("Edit Plain Dictation in Modes")
                            .accessibilityIdentifier(AccessibilityID.Settings.General.editPlainDictation)
                    }
                }
            } header: {
                Text("Plain Dictation")
            } footer: {
                Text(directTrigger == nil
                    ? "Choose a shortcut and how it starts in Modes. Plain Dictation is used whenever no other mode matches."
                    : "Plain Dictation is used whenever no other mode matches.")
            }

            Section("Shortcuts") {
                LabeledContent {
                    ShortcutWell(key: $model.addVocabularyShortcut, profile: .actionChord, accessibilityID: AccessibilityID.Settings.General.addVocabularyShortcut)
                } label: {
                    ShortcutFieldLabel("Add to Vocabulary", shadowed: vocabularyShadowed)
                }
                if vocabularyShadowed { ShadowedHotkeyNote() }
                Text("Opens a panel to add a word or correction. Selected text is filled in for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent {
                    ShortcutWell(key: $model.pasteLastShortcut, profile: .actionChord, accessibilityID: AccessibilityID.Settings.General.pasteLastShortcut)
                } label: {
                    ShortcutFieldLabel("Paste last dictation", shadowed: pasteLastShadowed)
                }
                if pasteLastShadowed { ShadowedHotkeyNote() }
                Text("Pastes your most recent dictation result.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Prefer this microphone", selection: $model.inputDeviceUID) {
                    ForEach(model.inputDeviceOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Settings.General.inputDevice)
                Text(model.microphoneStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Microphone")
            } footer: {
                Text("Choose one to always use it, or follow your Mac’s current input.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play dictation sounds", isOn: $model.sounds)
                    .accessibilityIdentifier(AccessibilityID.Settings.General.sounds)
                if model.sounds {
                    LabeledContent("Dictation sounds volume") {
                        Slider(
                            value: $model.soundVolume, in: 0...1,
                            onEditingChanged: model.soundVolumeEditingChanged,
                            minimumValueLabel:
                                Image(systemName: model.soundVolume > 0 ? "speaker.fill" : "speaker.slash.fill"),
                            maximumValueLabel: Image(systemName: "speaker.wave.3.fill"),
                            label: { Text("Dictation sounds volume") })
                            .labelsHidden()
                            .frame(width: SettingsMetrics.volumeSliderWidth)
                            .accessibilityIdentifier(AccessibilityID.Settings.General.soundVolume)
                    }
                }
            } header: {
                Text("Sound feedback")
            } footer: {
                Text("Sounds mark when dictation starts, completes, is canceled, or needs attention. Maximum plays them at full level; your Mac’s output volume still applies.")
            }

            Section {
                Toggle("Keep your Mac awake", isOn: $model.keepDisplayAwake)
                    .accessibilityIdentifier(AccessibilityID.Settings.General.keepDisplayAwake)
                Picker("Other audio", selection: $model.otherAudio) {
                    Text("Mute").tag(OtherAudio.mute)
                    Text("Quiet").tag(OtherAudio.quiet)
                    Text("Unchanged").tag(OtherAudio.unchanged)
                }
                .accessibilityIdentifier(AccessibilityID.Settings.General.otherAudio)
            } header: {
                Text("During dictation")
            } footer: {
                Text("These settings apply only while you dictate. Quiet turns other audio down instead of silencing it, so you can still hear a call or a video.")
            }

            Section("Startup") {
                Toggle("Open \(Branding.appName) when you log in", isOn: $model.loadOnLogin)
                    .accessibilityIdentifier(AccessibilityID.Settings.General.loadOnLogin)
            }

        }
        .formStyle(.grouped)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func shortcutDisplay(_ key: String) -> some View {
        if let descriptor = try? KeyDescriptor(parsing: key) {
            KeycapView(descriptor: descriptor)
        } else {
            Text(key)
        }
    }
}

struct ShortcutFieldLabel: View {
    let title: String
    let shadowed: Bool

    init(_ title: String, shadowed: Bool) {
        self.title = title
        self.shadowed = shadowed
    }

    var body: some View {
        HStack(spacing: 5) {
            if shadowed { Circle().fill(.red).frame(width: 7, height: 7) }
            Text(title)
        }
        .accessibilityLabel(shadowed ? "\(title), needs attention" : title)
    }
}

struct ShadowedHotkeyNote: View {
    var body: some View {
        IssueText("A mode (or another shortcut) already uses this — it won’t fire. Pick a unique combo.")
    }
}
