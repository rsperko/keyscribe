import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics

enum PermissionStatus: Equatable {
    case granted, denied, notDetermined
}

enum Permissions {
    static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func inputMonitoringStatus() -> PermissionStatus {
        CGPreflightListenEventAccess() ? .granted : .denied
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    static func accessibilityStatus(prompt: Bool = false) -> PermissionStatus {
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts) ? .granted : .notDetermined
    }

    @MainActor
    static func openSettings(_ pane: SettingsPane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    enum SettingsPane {
        case microphone, inputMonitoring, accessibility

        var urlString: String {
            let base = "x-apple.systempreferences:com.apple.preference.security?"
            switch self {
            case .microphone: return base + "Privacy_Microphone"
            case .inputMonitoring: return base + "Privacy_ListenEvent"
            case .accessibility: return base + "Privacy_Accessibility"
            }
        }
    }
}
