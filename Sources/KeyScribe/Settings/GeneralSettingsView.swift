import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel
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
