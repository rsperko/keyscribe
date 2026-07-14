import SwiftUI
import KeyScribeKit

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel
    var vocabularyShadowed = false
    var pasteLastShadowed = false
    // Edits route through onUpdatePlainDictation so the same _direct.toml and live HotkeyMonitor refresh
    // as when this is changed in Modes.
    var directMode: Mode?
    var allModes: [Mode] = []
    var actionShortcuts: [TriggerKeyConflicts.RivalBinding] = []
    var onUpdatePlainDictation: (Mode) -> Void = { _ in }

    var body: some View {
        Form {
            Section("Dictation") {
                if let directMode {
                    let trigger = ModeTrigger(
                        mode: directMode, allModes: allModes,
                        actionShortcuts: actionShortcuts, onUpdate: onUpdatePlainDictation)
                    ModeTriggerRow(
                        mode: directMode, onUpdate: onUpdatePlainDictation, label: "Dictation key",
                        accessibilityID: AccessibilityID.Settings.General.dictationTrigger)
                    Text("Hold it to dictate in any app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TriggerConflictLabel(conflict: trigger.conflict)
                    TriggerOverlapLabel(overlap: trigger.overlap)
                }
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
                Picker("Use this microphone", selection: $model.inputDeviceUID) {
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

            Section("Audio and system behavior") {
                Toggle("Play start and stop sounds", isOn: $model.sounds)
                    .accessibilityIdentifier(AccessibilityID.Settings.General.sounds)
                Toggle("Keep your Mac awake", isOn: $model.keepDisplayAwake)
                    .accessibilityIdentifier(AccessibilityID.Settings.General.keepDisplayAwake)
                Toggle("Mute all other audio", isOn: $model.muteSystemAudio)
                    .accessibilityIdentifier(AccessibilityID.Settings.General.muteSystemAudio)
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
