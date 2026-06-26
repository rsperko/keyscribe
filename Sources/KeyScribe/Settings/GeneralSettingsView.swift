import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel
    var dictionaryShadowed = false
    var replacementShadowed = false
    var pasteLastShadowed = false

    var body: some View {
        Form {
            Section("While dictating") {
                Toggle("Start and end sounds", isOn: $model.sounds)
                Toggle("Keep display awake", isOn: $model.keepDisplayAwake)
                Toggle("Mute system audio", isOn: $model.muteSystemAudio)
            }

            Section {
                Picker("Preferred input device", selection: $model.inputDeviceUID) {
                    ForEach(model.inputDeviceOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("KeyScribe captures from this device. If it is unavailable it falls back to the system default and switches back when the device returns.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Start KeyScribe at login", isOn: $model.loadOnLogin)
            }

            Section {
                SettingRow(
                    title: "Add Dictionary Entry",
                    result: "Opens a panel to teach KeyScribe a word.",
                    help: "Optional global shortcut. With text selected when you press it, the word is pre-filled. Leave unset to use the menu instead.")
                {
                    VStack(alignment: .trailing, spacing: 4) {
                        HotkeyRecorder(key: $model.addDictionaryShortcut)
                        if dictionaryShadowed { ShadowedHotkeyNote() }
                    }
                }
                SettingRow(
                    title: "Add Replacement",
                    result: "Opens a panel to add a heard→insert rule.",
                    help: "Optional global shortcut. With text selected when you press it, the “When you say” field is pre-filled. Leave unset to use the menu instead.")
                {
                    VStack(alignment: .trailing, spacing: 4) {
                        HotkeyRecorder(key: $model.addReplacementShortcut)
                        if replacementShadowed { ShadowedHotkeyNote() }
                    }
                }
                SettingRow(
                    title: "Paste Last Dictation",
                    result: "Re-inserts your most recent dictation result.",
                    help: "Optional global shortcut. Leave unset to use the menu instead.")
                {
                    VStack(alignment: .trailing, spacing: 4) {
                        HotkeyRecorder(key: $model.pasteLastShortcut)
                        if pasteLastShadowed { ShadowedHotkeyNote() }
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("These are also in the menu bar menu. Use a modifier combo (e.g. ⌃⌥⇧D) to avoid clashing with apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("History") {
                SettingRow(
                    title: "Keep dictation history on this Mac",
                    result: "Audio is never saved; stored text can be sensitive.",
                    help: "Stores transcripts and final text locally so you can search and correct them. Nothing leaves this Mac. Password-field dictations are never saved; for other sensitive work, lower retention below or exclude a mode in its Result handling.")
                {
                    Toggle("", isOn: $model.historyEnabled).labelsHidden()
                }
                if model.historyEnabled {
                    Stepper("Keep for \(model.retentionDays) days", value: $model.retentionDays, in: 1...365)
                }
            }

            Section {
                Picker("Model memory", selection: $model.eviction) {
                    ForEach(model.evictions, id: \.id) { Text($0.label).tag($0.id) }
                }
            } header: {
                Text("Performance")
            } footer: {
                Text(model.evictionFooter)
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// Non-blocking breadcrumb: this shortcut collides with a higher-precedence hotkey (a Mode, or — for
// Add Replacement — Add to Dictionary), so it is shadowed and will not fire. Mode triggers win.
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
