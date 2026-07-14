import AppKit

// LSUIElement (.accessory) apps have no Dock icon, so their windows can fall behind other apps' with
// no reliable way to raise them. Flip to .regular while a real window is open, revert once the last
// closes. Ref-counted so overlapping windows don't drop the policy early.
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
