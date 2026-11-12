import CoreGraphics
import Testing
@testable import KeyScribeKit

struct HUDPositionPickerLayoutTests {
    static let marker = HUDPositionPickerLayout.markerSize
    static let frames = [
        CGRect(x: 0, y: 0, width: 1728, height: 1079),
        CGRect(x: 0, y: 0, width: 800, height: 500),
        CGRect(x: -1920, y: 240, width: 1920, height: 1055),
        CGRect(x: 0, y: 0, width: 480, height: 300),
    ]

    @Test(arguments: frames)
    func offersOneTargetForEveryAnchor(_ frame: CGRect) {
        let layout = HUDPositionPickerLayout(in: frame)
        #expect(layout.targets.map(\.anchor) == HUDAnchor.allCases)
    }

    @Test func aMarkerIsACompactButtonAtItsAnchor() {
        let frame = Self.frames[0]
        let layout = HUDPositionPickerLayout(in: frame)
        for target in layout.targets {
            #expect(target.frame.size == Self.marker)
            #expect(target.frame.origin == target.anchor.origin(in: frame, size: Self.marker))
        }
    }

    @Test func theInstructionsGetTheRoomBetweenTheMarkers() {
        let layout = HUDPositionPickerLayout(in: Self.frames[1])
        #expect(layout.instruction.width >= 300)
        #expect(layout.instruction.height >= 200)
    }

    @Test(arguments: frames)
    func everythingStaysInsideTheUsableFrame(_ frame: CGRect) {
        let layout = HUDPositionPickerLayout(in: frame)
        for target in layout.targets {
            #expect(frame.contains(target.frame))
            #expect(target.frame.width > 0 && target.frame.height > 0)
        }
        #expect(frame.contains(layout.instruction))
        #expect(layout.instruction.width > 0 && layout.instruction.height > 0)
    }

    @Test(arguments: frames)
    func nothingOverlaps(_ frame: CGRect) {
        let layout = HUDPositionPickerLayout(in: frame)
        let rects = layout.targets.map(\.frame) + [layout.instruction]
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                #expect(!a.intersects(b))
            }
        }
    }
}
