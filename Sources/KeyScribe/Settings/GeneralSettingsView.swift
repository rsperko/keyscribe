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
    @State private var shortcutsExpanded = false

    var body: some View {
        Form {
            Section("Dictation") {
                LabeledContent {
                    HStack(spacing: 10) {
                        if let descriptor = plainDictationTrigger {
                            KeycapView(descriptor: descriptor)
                        } else {
                            Text("Not set").foregroundStyle(.secondary)
                        }
                        Button("Change key…", action: onOpenPlainDictation)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(AccessibilityID.Settings.General.changeDictationTrigger)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dictation key")
                        Text("Hold it to dictate in any app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Settings.General.dictationTrigger)
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
                Text("Choose a microphone to use it every time, or let \(Branding.appName) follow your Mac’s current input.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("During dictation") {
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

            Section {
                DisclosureSection(isExpanded: $shortcutsExpanded) {
                    DisclosureSummaryLabel(
                        title: "Optional shortcuts",
                        summary: "Add words or paste your last result")
                } content: {
                    LabeledContent("Add to Vocabulary") {
                        ShortcutWell(key: $model.addVocabularyShortcut, profile: .actionChord, accessibilityID: AccessibilityID.Settings.General.addVocabularyShortcut)
                    }
                    Text("Opens a panel to add a word or correction. Selected text is filled in for you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if vocabularyShadowed { ShadowedHotkeyNote() }
                    LabeledContent("Paste last dictation") {
                        ShortcutWell(key: $model.pasteLastShortcut, profile: .actionChord, accessibilityID: AccessibilityID.Settings.General.pasteLastShortcut)
                    }
                    Text("Pastes your most recent dictation result.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if pasteLastShadowed { ShadowedHotkeyNote() }
                    Text("Both are also available from the \(Branding.appName) menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Shortcuts")
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
