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

    @Test func onlyABottomAnchorKeepsItsBottomEdgeFixed() {
        #expect(HUDAnchor.allCases.filter(\.keepsBottomEdge) == [.bottomLeft, .bottomCenter, .bottomRight])
    }
}

struct HUDPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let header = CGSize(width: 280, height: 54)

    @Test(arguments: HUDAnchor.allCases)
    func theHeaderSitsAtTheAnchorWhateverTheBody(_ anchor: HUDAnchor) {
        let alone = anchor.placement(in: screen, header: header, body: nil)
        #expect(alone.panel == alone.header)
        #expect(alone.header.origin == anchor.origin(in: screen, size: header))
        for body in [CGFloat(40), 200, 360] {
            let placed = anchor.placement(in: screen, header: header, body: body)
            #expect(placed.header == alone.header)
            #expect(placed.panel.height == header.height + body)
            #expect(placed.panel.contains(placed.header))
            #expect(screen.contains(placed.panel))
        }
    }

    @Test(arguments: HUDAnchor.allCases)
    func theBodyOpensAwayFromTheAnchoredEdge(_ anchor: HUDAnchor) {
        let placed = anchor.placement(in: screen, header: header, body: 200)
        #expect(placed.bodyAbove == anchor.keepsBottomEdge)
    }

    @Test func aSideAnchorOpensAboveOnlyWhenBelowCannotFit() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 240)
        #expect(!HUDAnchor.centerLeft.placement(in: screen, header: header, body: 200).bodyAbove)
        let tight = HUDAnchor.centerLeft.placement(in: short, header: header, body: 150)
        #expect(tight.bodyAbove)
        #expect(short.contains(tight.panel))
    }

    @Test func aBodyTallerThanTheScreenIsShortenedAndScrolls() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 160)
        let placed = HUDAnchor.bottomLeft.placement(in: short, header: header, body: 300)
        #expect(placed.body == short.height - header.height)
        #expect(placed.bodyScrolls)
        #expect(short.contains(placed.panel))
        #expect(!HUDAnchor.bottomLeft.placement(in: screen, header: header, body: 300).bodyScrolls)
    }

    @Test func theListCapIsHalfTheScreenWithinFixedBounds() {
        #expect(HUDAnchor.listCap(screenHeight: 2000) == HUDAnchor.listCapRange.upperBound)
        #expect(HUDAnchor.listCap(screenHeight: 200) == HUDAnchor.listCapRange.lowerBound)
        let middle = HUDAnchor.listCap(screenHeight: 700)
        #expect(middle > HUDAnchor.listCapRange.lowerBound && middle < HUDAnchor.listCapRange.upperBound)
    }
}
