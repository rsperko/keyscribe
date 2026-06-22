import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel
    var dictionaryShadowed = false
    var replacementShadowed = false
    @State private var modelBehaviorExpanded = false

    var body: some View {
        Form {
            Section("While dictating") {
                Toggle("Start and end sounds", isOn: $model.sounds)
                Toggle("Keep display awake", isOn: $model.keepDisplayAwake)
                Toggle("Mute system audio", isOn: $model.muteSystemAudio)
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
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Both are also in the menu bar menu. Use a modifier combo (e.g. ⌃⌥⇧D) to avoid clashing with apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("History") {
                SettingRow(
                    title: "Keep dictation history on this Mac",
                    result: "Audio is never saved; stored text can be sensitive.",
                    help: "Stores each dictation's transcript and final text locally so you can search and correct them. Nothing leaves this Mac. For sensitive work, lower retention below or exclude a mode in its Result handling.")
                {
                    Toggle("", isOn: $model.historyEnabled).labelsHidden()
                }
                if model.historyEnabled {
                    Stepper("Keep for \(model.retentionDays) days", value: $model.retentionDays, in: 1...365)
                }
            }

            Section {
                DisclosureSection("Advanced model behavior", isExpanded: $modelBehaviorExpanded) {
                    Text("Trade first-response speed against memory use. Reloading a freed model adds a brief delay.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Model memory", selection: $model.eviction) {
                        ForEach(SettingsModel.evictions, id: \.id) { Text($0.label).tag($0.id) }
                    }
                }
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
