import AppKit
import SwiftUI

struct PermissionsSettingsView: View {
    var accessibilityTapActive: () -> Bool = { true }
    var onRelaunch: () -> Void = {}
    @State private var microphoneStatus = Permissions.microphoneStatus()
    @State private var accessibilityStatus = Permissions.accessibilityStatus()
    @State private var tapActive = true

    var body: some View {
        Form {
            Section("Permissions") {
                Text("\(Branding.appName) asks for access only when a capability needs it. You can review or repair access here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PermissionRow(
                    title: "Microphone", status: microphoneStatus,
                    purpose: "Lets \(Branding.appName) hear a dictation.",
                    unavailable: "Dictation cannot start without microphone access.",
                    request: {
                        Task {
                            _ = await Permissions.requestMicrophone()
                            microphoneStatus = Permissions.microphoneStatus()
                        }
                    },
                    openSettings: { Permissions.openSettings(.microphone) })
                PermissionRow(
                    title: "Accessibility", status: accessibilityStatus,
                    purpose: "Lets \(Branding.appName) detect a modifier-key trigger and paste finished text into the focused field.",
                    unavailable: "Modifier-key triggers won't start dictation, and finished text is copied instead of inserted.",
                    request: {
                        _ = Permissions.accessibilityStatus(prompt: true)
                    },
                    openSettings: { Permissions.openSettings(.accessibility) })
                if accessibilityStatus == .granted && !tapActive {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Accessibility is granted, but it only takes effect after a relaunch. Until then, modifier-key triggers won't start dictation.",
                            systemImage: "arrow.clockwise.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Quit & Relaunch to Apply", action: onRelaunch)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Permission grants land out-of-process: Microphone is toggled in System Settings (re-checked
        // when the app reactivates), while Accessibility is granted in another app that never
        // reactivates us — so there is no event to hook. TCC exposes no "permission changed"
        // callback, so we poll, but only while this pane is on screen (.task is cancelled on disappear).
        .task {
            while !Task.isCancelled {
                refreshPermissions()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        microphoneStatus = Permissions.microphoneStatus()
        accessibilityStatus = Permissions.accessibilityStatus()
        tapActive = accessibilityTapActive()
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
