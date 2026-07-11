import SwiftUI
import KeyScribeKit

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel
    var vocabularyShadowed = false
    var pasteLastShadowed = false
    // The Plain Dictation (Direct mode) trigger — a read-only pointer, not a duplicate setting (the trigger
    // is owned by the Direct mode, edited only in Modes). Passed in by SettingsRootView (UX2 phase 3c).
    var plainDictationTrigger: KeyDescriptor?
    var onOpenPlainDictation: () -> Void = {}
    @State private var advancedModelExpanded = false

    var body: some View {
        Form {
            Section("Dictation") {
                LabeledContent("Dictation trigger") {
                    if let descriptor = plainDictationTrigger {
                        KeycapView(descriptor: descriptor)
                    } else {
                        Text("None set").foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Settings.General.dictationTrigger)
                Text("Hold to dictate anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Change in Modes…", action: onOpenPlainDictation)
                    .buttonStyle(.link)
                    .accessibilityIdentifier(AccessibilityID.Settings.General.changeDictationTrigger)
            }

            Section("While dictating") {
                Toggle("Start and end sounds", isOn: $model.sounds)
                    .accessibilityIdentifier(AccessibilityID.Settings.General.sounds)
                Toggle("Keep display awake", isOn: $model.keepDisplayAwake)
                    .accessibilityIdentifier(AccessibilityID.Settings.General.keepDisplayAwake)
                Toggle("Mute system audio", isOn: $model.muteSystemAudio)
                    .accessibilityIdentifier(AccessibilityID.Settings.General.muteSystemAudio)
            }

            Section {
                Picker("Preferred input device", selection: $model.inputDeviceUID) {
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
                Text("If the preferred microphone is unavailable, \(Branding.appName) uses the macOS input until it reconnects.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Start \(Branding.appName) at login", isOn: $model.loadOnLogin)
                    .accessibilityIdentifier(AccessibilityID.Settings.General.loadOnLogin)
            }

            Section {
                SettingRow(
                    title: "Add to Vocabulary",
                    result: "Opens a panel to add a word or replacement.",
                    help: "Optional global shortcut. With text selected when you press it, the word or heard phrase is pre-filled. Leave unset to use the menu instead.")
                {
                    VStack(alignment: .trailing, spacing: 4) {
                        ShortcutWell(key: $model.addVocabularyShortcut, profile: .actionChord, accessibilityID: AccessibilityID.Settings.General.addVocabularyShortcut)
                        if vocabularyShadowed { ShadowedHotkeyNote() }
                    }
                }
                SettingRow(
                    title: "Paste Last Dictation",
                    result: "Re-inserts your most recent dictation result.",
                    help: "Optional global shortcut. Leave unset to use the menu instead.")
                {
                    VStack(alignment: .trailing, spacing: 4) {
                        ShortcutWell(key: $model.pasteLastShortcut, profile: .actionChord, accessibilityID: AccessibilityID.Settings.General.pasteLastShortcut)
                        if pasteLastShadowed { ShadowedHotkeyNote() }
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("These are also in the menu bar menu. Use a modifier combo (e.g. ⌃⌥⇧V) to avoid clashing with apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Performance") {
                DisclosureSection(isExpanded: $advancedModelExpanded) {
                    DisclosureSummaryLabel(title: "Advanced model behavior", summary: model.evictionShortLabel)
                } content: {
                    Picker("Warm-up", selection: $model.eviction) {
                        ForEach(model.evictions, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.General.eviction)
                    Text(model.evictionFooter)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier(AccessibilityID.Settings.General.advancedModelBehavior)
            }

        }
        .formStyle(.grouped)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ShadowedHotkeyNote: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.red).frame(width: 7, height: 7)
            Text("A mode (or another shortcut) already uses this — it won’t fire. Pick a unique combo.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityLabel("Shortcut conflict: this shortcut is shadowed and will not fire")
    }
}
