import AppKit
@testable import KeyScribeApp

@MainActor
final class FakeDisplays {
    var frames: [CGDirectDisplayID: CGRect]
    var focused: CGDirectDisplayID?

    init(_ frames: [CGDirectDisplayID: CGRect], focused: CGDirectDisplayID? = nil) {
        self.frames = frames
        self.focused = focused
    }

    static func single(_ frame: CGRect) -> HUDDisplays { FakeDisplays([1: frame], focused: 1).displays }

    var displays: HUDDisplays {
        HUDDisplays(
            focused: { self.focused },
            holding: { window in
                let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
                return self.frames.first { $0.value.contains(center) }?.key ?? self.frames.keys.min()
            },
            visibleFrame: { id in self.frames[id] }, followsScreenChanges: false)
    }
}

extension HUDDisplays {
    @MainActor static var unfocused: HUDDisplays {
        var displays = HUDDisplays.live
        displays.focused = { nil }
        displays.followsScreenChanges = false
        return displays
    }
}
