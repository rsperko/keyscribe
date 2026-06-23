import AppKit

// KeyScribe runs as an LSUIElement agent (.accessory) with no Dock icon, which leaves its few real
// windows (Settings, onboarding) prone to falling behind other apps' windows with no reliable way to
// raise them. While such a window is open we flip to .regular — a temporary Dock icon and proper window
// ordering — and revert to .accessory once the last one closes. Ref-counted so overlapping windows don't
// drop the policy early.
@MainActor
enum AppActivationPolicy {
    private static var holders = 0

    static func pushRegular() {
        holders += 1
        if holders == 1 { NSApp.setActivationPolicy(.regular) }
    }

    static func popRegular() {
        guard holders > 0 else { return }
        holders -= 1
        if holders == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}
