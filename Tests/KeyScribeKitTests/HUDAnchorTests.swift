import CoreGraphics
import Testing
@testable import KeyScribeKit

struct HUDAnchorTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 280, height: 92)
    let margin: CGFloat = 24

    @Test func bottomCenterIsHorizontallyCentered() {
        let o = HUDAnchor.bottomCenter.origin(in: screen, size: size, margin: margin)
        #expect(o.x == screen.midX - size.width / 2)
        #expect(o.y == screen.minY + margin)
    }

    @Test func topRightHugsTheTopRightCorner() {
        let o = HUDAnchor.topRight.origin(in: screen, size: size, margin: margin)
        #expect(o.x == screen.maxX - size.width - margin)
        #expect(o.y == screen.maxY - size.height - margin)
    }

    @Test func centerLeftIsVerticallyCentered() {
        let o = HUDAnchor.centerLeft.origin(in: screen, size: size, margin: margin)
        #expect(o.x == screen.minX + margin)
        #expect(o.y == screen.midY - size.height / 2)
    }

    @Test func everyOriginKeepsThePanelWithinTheVisibleFrame() {
        for anchor in HUDAnchor.allCases {
            let o = anchor.origin(in: screen, size: size, margin: margin)
            #expect(o.x >= screen.minX)
            #expect(o.y >= screen.minY)
            #expect(o.x + size.width <= screen.maxX)
            #expect(o.y + size.height <= screen.maxY)
        }
    }

    @Test func nearestSnapsToTheClosestCorner() {
        let nearBottomLeft = CGPoint(x: 60, y: 60)
        #expect(HUDAnchor.nearest(toCenter: nearBottomLeft, in: screen, size: size, margin: margin) == .bottomLeft)

        let nearTopRight = CGPoint(x: 960, y: 760)
        #expect(HUDAnchor.nearest(toCenter: nearTopRight, in: screen, size: size, margin: margin) == .topRight)
    }

    @Test func nearestSnapsToTopCenterFromTopMiddle() {
        let topMiddle = CGPoint(x: screen.midX, y: 770)
        #expect(HUDAnchor.nearest(toCenter: topMiddle, in: screen, size: size, margin: margin) == .topCenter)
    }
}
