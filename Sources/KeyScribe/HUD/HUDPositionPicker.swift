import AppKit
import KeyScribeKit
import SwiftUI

extension HUDAnchor {
    var positionName: String {
        switch self {
        case .topLeft: "Top left"
        case .topCenter: "Top center"
        case .topRight: "Top right"
        case .centerLeft: "Center left"
        case .centerRight: "Center right"
        case .bottomLeft: "Bottom left"
        case .bottomCenter: "Bottom center"
        case .bottomRight: "Bottom right"
        }
    }
}

@MainActor
final class HUDPositionPickerController {
    struct Display: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect

        init(frame: CGRect, visibleFrame: CGRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }

        init(_ screen: NSScreen) {
            self.init(frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }

    static let heading = "Move HUD"
    static let instructions = [
        "Click a position around the screen.",
        "You can also drag the HUD during dictation.",
    ]
    static let cancelHint = "Esc to cancel"

    private let currentAnchor: () -> HUDAnchor
    private let select: (HUDAnchor) -> Void
    private let hudDisplay: () -> Display?
    private let displays: () -> [Display]
    private let appearance: () -> HUDAppearance
    private let order: (NSPanel, Bool) -> Void
    private var panels: [NSPanel] = []
    private var screenObserver: NSObjectProtocol?

    private(set) var display: Display?
    private(set) var markedAnchor: HUDAnchor?
    private(set) var layout: HUDPositionPickerLayout?

    var isOpen: Bool { !panels.isEmpty }
    var panelCount: Int { panels.count }
    var isObservingDisplays: Bool { screenObserver != nil }

    init(
        currentAnchor: @escaping () -> HUDAnchor,
        select: @escaping (HUDAnchor) -> Void,
        hudDisplay: @escaping () -> Display?,
        displays: @escaping () -> [Display] = { NSScreen.screens.map(Display.init) },
        appearance: @escaping () -> HUDAppearance = { .system },
        order: @escaping (NSPanel, Bool) -> Void = { panel, key in
            if key { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        }
    ) {
        self.currentAnchor = currentAnchor
        self.select = select
        self.hudDisplay = hudDisplay
        self.displays = displays
        self.appearance = appearance
        self.order = order
    }

    func open() {
        guard !isOpen, let display = hudDisplay() else { return }
        let marked = currentAnchor()
        let local = display.visibleFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let layout = HUDPositionPickerLayout(in: local)
        self.display = display
        self.markedAnchor = marked
        self.layout = layout

        let picker = makePanel(frame: display.frame, keyable: true)
        picker.contentView = NSHostingView(rootView: HUDPositionPickerView(
            layout: layout, height: display.frame.height, current: marked,
            onSelect: { [weak self] in self?.choose($0) },
            onCancel: { [weak self] in self?.cancel() }))
        picker.setAccessibilityLabel(Self.heading)
        let catchers = displays().filter { $0.frame != display.frame }.map { other in
            let panel = makePanel(frame: other.frame, keyable: false)
            panel.cancelsOnMouseDown = true
            panel.ignoresMouseEvents = false
            let surface = NSView()
            surface.wantsLayer = true
            surface.layer?.backgroundColor = HUDPositionPickerView.clickSurface.cgColor
            panel.contentView = surface
            return panel
        }
        panels = [picker] + catchers
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        for panel in catchers { order(panel, false) }
        order(picker, true)
    }

    func choose(_ anchor: HUDAnchor) {
        guard isOpen else { return }
        close()
        select(anchor)
    }

    func cancel() { close() }

    private func close() {
        guard isOpen else { return }
        let closing = panels
        panels = []
        display = nil
        markedAnchor = nil
        layout = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for panel in closing {
            (panel as? PickerPanel)?.onCancel = nil
            panel.orderOut(nil)
            panel.contentView = nil
        }
    }

    private func makePanel(frame: CGRect, keyable: Bool) -> PickerPanel {
        let panel = PickerPanel(
            contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.keyable = keyable
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = appearance().nsAppearance()
        panel.setFrame(frame, display: false)
        return panel
    }
}

private final class PickerPanel: NSPanel {
    var keyable = false
    var cancelsOnMouseDown = false
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onCancel?()
            return
        }
        if cancelsOnMouseDown, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            onCancel?()
            return
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onCancel?()
    }
}

struct HUDPositionPickerView: View {
    static let scrim = NSColor.black.withAlphaComponent(0.25)
    static let clickSurface = NSColor.black.withAlphaComponent(0.01)

    let layout: HUDPositionPickerLayout
    let height: CGFloat
    let current: HUDAnchor
    let onSelect: (HUDAnchor) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: Self.scrim)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
                .accessibilityHidden(true)
            HUDPositionInstructions()
                .frame(maxWidth: layout.instruction.width, maxHeight: layout.instruction.height)
                .position(x: layout.instruction.midX, y: height - layout.instruction.midY)
                .allowsHitTesting(false)
            ForEach(layout.targets, id: \.anchor) { target in
                HUDPositionMarker(anchor: target.anchor, isCurrent: target.anchor == current) {
                    onSelect(target.anchor)
                }
                .frame(width: target.frame.width, height: target.frame.height)
                .position(x: target.frame.midX, y: height - target.frame.midY)
            }
        }
        .ignoresSafeArea()
    }
}

private struct HUDPositionInstructions: View {
    var body: some View {
        VStack(spacing: 6) {
            Text(HUDPositionPickerController.heading)
                .font(.system(size: 28, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 4)
            ForEach(HUDPositionPickerController.instructions, id: \.self) { line in
                Text(line).font(.title3)
            }
            Text(HUDPositionPickerController.cancelHint)
                .font(.callout.weight(.medium))
                .opacity(0.85)
                .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.5), radius: 10)
        .background(
            Ellipse()
                .fill(.black.opacity(0.8))
                .padding(.horizontal, -90)
                .padding(.vertical, -55)
                .blur(radius: 45))
    }
}

private struct HUDPositionMarker: View {
    let anchor: HUDAnchor
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isCurrent { Image(systemName: "checkmark").accessibilityHidden(true) }
                Text(anchor.positionName).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(HUDPositionMarkerStyle(isCurrent: isCurrent, hovering: hovering, focused: focused))
        .focused($focused)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .accessibilityLabel(anchor.positionName)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.HUD.positionTarget(anchor.rawValue))
    }
}

private struct HUDPositionMarkerStyle: ButtonStyle {
    let isCurrent: Bool
    let hovering: Bool
    let focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        configuration.label
            .font(.callout.weight(isCurrent ? .semibold : .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .background(tint(pressed: configuration.isPressed), in: shape)
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: isCurrent || hovering ? 2 : 1))
            .overlay(shape.inset(by: -4).strokeBorder(Color.accentColor, lineWidth: 3).opacity(focused ? 1 : 0))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .contentShape(shape)
    }

    private func tint(pressed: Bool) -> Color {
        if pressed { return Color.accentColor.opacity(0.55) }
        if hovering { return Color.primary.opacity(0.16) }
        return isCurrent ? Color.accentColor.opacity(0.22) : .clear
    }

    private var border: Color {
        if isCurrent { return .accentColor }
        return Color.primary.opacity(hovering ? 0.9 : contrast == .increased ? 0.7 : 0.4)
    }
}
