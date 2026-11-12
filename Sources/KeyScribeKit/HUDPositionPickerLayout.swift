import CoreGraphics

public struct HUDPositionPickerLayout: Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        public let anchor: HUDAnchor
        public let frame: CGRect
    }

    public static let gap: CGFloat = 16
    public static let markerSize = CGSize(width: 140, height: 40)

    public let targets: [Target]
    public let instruction: CGRect

    public init(
        in visibleFrame: CGRect, marker: CGSize = HUDPositionPickerLayout.markerSize,
        margin: CGFloat = HUDAnchor.defaultMargin
    ) {
        let size = CGSize(
            width: Self.fitted(marker.width, across: visibleFrame.width, margin: margin),
            height: Self.fitted(marker.height, across: visibleFrame.height, margin: margin))
        targets = HUDAnchor.allCases.map {
            Target(anchor: $0, frame: CGRect(origin: $0.origin(in: visibleFrame, size: size, margin: margin), size: size))
        }
        instruction = visibleFrame.insetBy(
            dx: margin + size.width + Self.gap, dy: margin + size.height + Self.gap)
    }

    private static func fitted(_ wanted: CGFloat, across extent: CGFloat, margin: CGFloat) -> CGFloat {
        min(wanted, max(0, ((extent - 2 * margin - 2 * gap) / 3).rounded(.down)))
    }
}
