import CoreGraphics

public enum HUDAnchor: String, CaseIterable, Sendable {
    case topLeft, topCenter, topRight
    case centerLeft, centerRight
    case bottomLeft, bottomCenter, bottomRight

    public static let `default`: HUDAnchor = .bottomCenter
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
