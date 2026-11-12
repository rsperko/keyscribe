import AppKit

final class HUDPanel: NSPanel {
    var allowsKey: () -> Bool = { true }
    override var canBecomeKey: Bool { allowsKey() }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        performDrag(with: event)
    }

    @MainActor
    static func make(content: NSView, size: NSSize) -> HUDPanel {
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        return panel
    }
}

@MainActor
final class HUDDragSnap {
    static let settle: Double = 0.15

    private var observer: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private var placing = false

    init(panel: NSWindow, snap: @escaping @MainActor (NSWindow) -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel, !self.placing else { return }
                self.pending?.cancel()
                let item = DispatchWorkItem { MainActor.assumeIsolated { snap(panel) } }
                self.pending = item
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: item)
            }
        }
    }

    func place(_ change: () -> Void) {
        placing = true
        change()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.placing = false }
        }
    }
}
