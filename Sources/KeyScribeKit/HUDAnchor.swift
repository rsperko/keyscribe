import CoreGraphics

public enum HUDAnchor: String, CaseIterable, Sendable {
    case topLeft, topCenter, topRight
    case centerLeft, centerRight
    case bottomLeft, bottomCenter, bottomRight

    public static let `default`: HUDAnchor = .bottomCenter

    public var keepsBottomEdge: Bool {
        switch self {
        case .bottomLeft, .bottomCenter, .bottomRight: true
        default: false
        }
    }
    public static let defaultMargin: CGFloat = 24

    public func origin(in visibleFrame: CGRect, size: CGSize, margin: CGFloat = HUDAnchor.defaultMargin) -> CGPoint {
        let x: CGFloat
        switch self {
        case .topLeft, .centerLeft, .bottomLeft:
            x = visibleFrame.minX + margin
        case .topCenter, .bottomCenter:
            x = visibleFrame.midX - size.width / 2
        case .topRight, .centerRight, .bottomRight:
            x = visibleFrame.maxX - size.width - margin
        }
        let y: CGFloat
        switch self {
        case .topLeft, .topCenter, .topRight:
            y = visibleFrame.maxY - size.height - margin
        case .centerLeft, .centerRight:
            y = visibleFrame.midY - size.height / 2
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = visibleFrame.minY + margin
        }
        return CGPoint(x: x, y: y)
    }

    public static let listCapRange: ClosedRange<CGFloat> = 140...360

    public static func listCap(screenHeight: CGFloat) -> CGFloat {
        min(listCapRange.upperBound, max(listCapRange.lowerBound, (screenHeight - 160) / 2))
    }

    public func placement(
        in screen: CGRect, header: CGSize, body: CGFloat?, margin: CGFloat = HUDAnchor.defaultMargin
    ) -> HUDPlacement {
        let anchored = CGRect(origin: origin(in: screen, size: header, margin: margin), size: header)
        guard let body else { return HUDPlacement(panel: anchored, header: anchored, bodyAbove: false, body: 0, bodyScrolls: false) }
        let shown = min(body, max(0, screen.height - header.height))
        let height = header.height + shown
        let above: Bool = switch self {
        case .bottomLeft, .bottomCenter, .bottomRight: true
        case .topLeft, .topCenter, .topRight: false
        case .centerLeft, .centerRight: anchored.maxY - height < screen.minY
        }
        let preferredY = above ? anchored.minY : anchored.maxY - height
        let y = min(max(preferredY, screen.minY), screen.maxY - height)
        let panel = CGRect(x: anchored.minX, y: y, width: header.width, height: height)
        let headerY = above ? panel.minY : panel.maxY - header.height
        return HUDPlacement(
            panel: panel, header: CGRect(x: anchored.minX, y: headerY, width: header.width, height: header.height),
            bodyAbove: above, body: shown, bodyScrolls: shown < body)
    }

    public static func nearest(
        toCenter center: CGPoint, in visibleFrame: CGRect,
        size: CGSize, margin: CGFloat = HUDAnchor.defaultMargin
    ) -> HUDAnchor {
        allCases.min { a, b in
            squaredDistance(a.center(in: visibleFrame, size: size, margin: margin), center)
                < squaredDistance(b.center(in: visibleFrame, size: size, margin: margin), center)
        } ?? .default
    }

    private func center(in visibleFrame: CGRect, size: CGSize, margin: CGFloat) -> CGPoint {
        let o = origin(in: visibleFrame, size: size, margin: margin)
        return CGPoint(x: o.x + size.width / 2, y: o.y + size.height / 2)
    }

    private static func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }
}

public struct HUDPlacement: Equatable, Sendable {
    public let panel: CGRect
    public let header: CGRect
    public let bodyAbove: Bool
    public let body: CGFloat
    public let bodyScrolls: Bool
}
