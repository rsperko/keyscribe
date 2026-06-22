import AppKit
import SwiftUI

struct PermissionsSettingsView: View {
    @State private var microphoneStatus = Permissions.microphoneStatus()
    @State private var inputMonitoringStatus = Permissions.inputMonitoringStatus()
    @State private var accessibilityStatus = Permissions.accessibilityStatus()

    // Permission grants land out-of-process: Microphone/Input Monitoring are toggled in System
    // Settings (we re-check when the app reactivates), while Accessibility is granted in another app
    // that never reactivates us — so there is no event to hook and we poll while the pane is visible.
    // TCC exposes no general "permission changed" callback, so this poll is the live-status mechanism.
    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permissions") {
                Text("KeyScribe asks for access only when a capability needs it. You can review or repair access here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PermissionRow(
                    title: "Microphone", status: microphoneStatus,
                    purpose: "Lets KeyScribe hear a dictation.",
                    unavailable: "Dictation cannot start without microphone access.",
                    request: {
                        Task {
                            _ = await Permissions.requestMicrophone()
                            microphoneStatus = Permissions.microphoneStatus()
                        }
                    },
                    openSettings: { Permissions.openSettings(.microphone) })
                PermissionRow(
                    title: "Input Monitoring", status: inputMonitoringStatus,
                    purpose: "Lets a mode's hotkey start dictation from any app.",
                    unavailable: "You can still open KeyScribe, but mode hotkeys cannot listen.",
                    request: {
                        Permissions.requestInputMonitoring()
                        Permissions.openSettings(.inputMonitoring)
                    },
                    openSettings: { Permissions.openSettings(.inputMonitoring) })
                PermissionRow(
                    title: "Accessibility", status: accessibilityStatus,
                    purpose: "Lets KeyScribe paste finished text into the focused field.",
                    unavailable: "Dictation can be transcribed, but KeyScribe copies it instead of inserting it.",
                    request: {
                        _ = Permissions.accessibilityStatus(prompt: true)
                        Permissions.openSettings(.accessibility)
                    },
                    openSettings: { Permissions.openSettings(.accessibility) })
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onReceive(pollTimer) { _ in refreshPermissions() }
    }

    private func refreshPermissions() {
        microphoneStatus = Permissions.microphoneStatus()
        inputMonitoringStatus = Permissions.inputMonitoringStatus()
        accessibilityStatus = Permissions.accessibilityStatus()
    }
}

private struct PermissionRow: View {
    let title: String
    let status: PermissionStatus
    let purpose: String
    let unavailable: String
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: status.symbol).foregroundStyle(status.color)
                Text(title)
                Spacer()
                Text(status.label).font(.caption).foregroundStyle(status.color)
            }
            Text(purpose).font(.caption).foregroundStyle(.secondary)
            if status != .granted {
                Text(unavailable).font(.caption).foregroundStyle(.secondary)
                HStack {
                    if status == .notDetermined {
                        Button("Allow", action: request)
                    }
                    Button("Open System Settings", action: openSettings)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(status.label). \(purpose)")
    }
}

private extension PermissionStatus {
    var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Needs attention"
        case .notDetermined: "Not allowed yet"
        }
    }

    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied: "exclamationmark.triangle.fill"
        case .notDetermined: "circle"
        }
    }

    var color: Color {
        switch self {
        case .granted: .green
        case .denied: .orange
        case .notDetermined: .secondary
        }
    }
}
