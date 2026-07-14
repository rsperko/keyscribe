import AppKit
import CoreGraphics
import SwiftUI
import KeyScribeKit

@MainActor
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .hidden
}

// Kept separate from HUDModel so only `LevelIndicator` rebuilds on each per-buffer level tick, not
// the whole HUD card (see render()).
@MainActor
final class HUDLevel: ObservableObject {
    @Published var level: Float = 0
}

@MainActor
final class HUDController: HUDPresenting {
    private static let panelWidth: CGFloat = 280
    private let model = HUDModel()
    private let levelModel = HUDLevel()
    private var panel: NSPanel?

    // Lets the focus-change guard distinguish our own overlay from the dictation target when inserting
    // into our own window (the onboarding trial). Nil until the panel is realized.
    var hudWindowID: CGWindowID? {
        guard let number = panel?.windowNumber, number > 0 else { return nil }
        return CGWindowID(number)
    }
    var onInsertLocalTranscript: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onEscapeCancel: (() -> Void)?
    var canCancel: (() -> Bool)?
    private var localKeyMonitor: Any?
    private var anchor: HUDAnchor = HUDAnchorStore.load()
    private var moveObserver: NSObjectProtocol?
    private var snapWorkItem: DispatchWorkItem?
    private var isRepositioning = false

    func render(_ state: HUDState) {
        // Same mode/latch, only the level changed: push just the level so the card chrome isn't rebuilt
        // on every audio tick.
        if case .recording(let mode, let level, let latched) = state,
           case .recording(let currentMode, _, let currentLatched) = model.state,
           mode == currentMode, latched == currentLatched {
            levelModel.level = level
            return
        }
        guard model.state != state else { return }
        let wasHidden: Bool = { if case .hidden = model.state { return true } else { return false } }()
        if case .recording(_, let level, _) = state {
            levelModel.level = level
        }
        model.state = state
        announce(state)
        if case .hidden = state {
            if panel?.isKeyWindow == true { relinquishKeyFocus() }
            fadeOutPanel()
        } else {
            showPanelIfNeeded()
            // Appear is instant (latency reads as sluggishness); reset alpha in case a fade-out was still
            // in flight.
            panel?.alphaValue = 1
            if let panel {
                resize(panel, to: state)
            }
            // Follow the focused window's screen only on hidden→visible, not on every level tick, so
            // recording never hops the HUD mid-dictation.
            if wasHidden, let panel { reposition(panel, to: focusedWindowScreen()) }
            // The HUD must hold key focus in every cancellable state so ESC-to-cancel reaches it as a local
            // keystroke — but synthesized ⌘C/⌘V/Return target whatever window IS key, so the controller
            // relinquishes focus momentarily around each one (see relinquishKeyFocus()).
            if state.holdsKeyFocus {
                panel?.makeKeyAndOrderFront(nil)
            } else if panel?.isKeyWindow == true {
                relinquishKeyFocus()
            } else {
                panel?.orderFrontRegardless()
            }
        }
    }

    // Realizes the panel ahead of the first dictation so the first `.recording` render is instant. Never
    // orders it on screen — render() does that once state leaves .hidden.
    func prewarm() {
        showPanelIfNeeded()
        panel?.layoutIfNeeded()
    }

    private func showPanelIfNeeded() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: HUDView(
            model: model,
            level: levelModel,
            onInsertLocalTranscript: { [weak self] in self?.onInsertLocalTranscript?() },
            onPasteLast: { [weak self] in self?.onPasteLast?() },
            onErrorAction: { action in
                switch action {
                case .openMicrophoneSettings: Permissions.openSettings(.microphone)
                case .openAccessibilitySettings: Permissions.openSettings(.accessibility)
                }
            }))
        // Let the panel grow to the content's intrinsic height (badges wrap, text never ellipsizes); the
        // fixed 280 width is unchanged. `resize` reads fittingSize and grows upward.
        hosting.sizingOptions = [.intrinsicContentSize]
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: HUDState.hidden.contentHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        self.panel = panel
        observeMoves(panel)
        reposition(panel)
        installLocalKeyMonitor()
    }

    private func resize(_ panel: NSPanel, to state: HUDState) {
        // contentHeight is a floor; take the max with the hosting view's actual fitting height. Force a
        // layout pass first — `model.state` was just mutated and SwiftUI may not have reconciled the
        // hosting view yet, so a cold `fittingSize` read can return the previous (smaller) state's height
        // and clip a wrap-grown state on a state→state transition.
        panel.contentView?.layoutSubtreeIfNeeded()
        let fittingHeight = panel.contentView?.fittingSize.height ?? 0
        let height = max(state.contentHeight, fittingHeight)
        let size = CGSize(width: Self.panelWidth, height: height)
        guard panel.frame.size != size else { return }
        isRepositioning = true
        let screen = panel.screen ?? NSScreen.main
        let origin = screen.map { anchor.origin(in: $0.visibleFrame, size: size) } ?? panel.frame.origin
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.isRepositioning = false }
        }
    }

    // The HUD panel is non-activating and usually not the focused element, so a changed accessibilityLabel
    // isn't read automatically — an explicit announcement is the only reliable VoiceOver cue for a state
    // change (ui_design.md §9). Level ticks never reach here (render early-returns on those).
    private func announce(_ state: HUDState) {
        guard let text = state.voiceOverAnnouncement, !text.isEmpty else { return }
        let element: Any = panel ?? NSApp as Any
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    func relinquishKeyFocus() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    // Fade out over ~120 ms (abrupt vanish is jarring); appear stays instant. The completion re-checks
    // state so a dictation starting mid-fade isn't ordered back out; reduce-motion hides immediately.
    private func fadeOutPanel() {
        guard let panel, panel.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if case .hidden = self.model.state { panel.orderOut(nil) }
                panel.alphaValue = 1
            }
        })
    }

    private func installLocalKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.canCancel?() == true else { return event }
            self.onEscapeCancel?()
            return nil
        }
    }

    // Anchors are resolution-independent — recomputed from visibleFrame each time — so a saved spot lands
    // correctly on any display; only the screen changes when the HUD follows the focused window.
    private func reposition(_ panel: NSPanel, to screen: NSScreen? = nil) {
        guard let screen = screen ?? panel.screen ?? NSScreen.main else { return }
        let origin = anchor.origin(in: screen.visibleFrame, size: panel.frame.size)
        // Our own setFrameOrigin posts didMove; guard so it isn't mistaken for a user drag. Cleared a
        // runloop tick later since the notification is delivered asynchronously.
        isRepositioning = true
        panel.setFrameOrigin(origin)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.isRepositioning = false }
        }
    }

    // Debounce until a drag settles, then snap to the nearest of the eight anchors and persist it.
    private func observeMoves(_ panel: NSPanel) {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidMove() }
        }
    }

    private func handleDidMove() {
        guard !isRepositioning else { return }
        snapWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.snapToNearestAnchor() }
        }
        snapWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func snapToNearestAnchor() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let frame = panel.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        anchor = HUDAnchor.nearest(toCenter: center, in: screen.visibleFrame, size: frame.size)
        HUDAnchorStore.save(anchor)
        reposition(panel)
    }

    func resetAnchor() {
        anchor = .default
        HUDAnchorStore.save(.default)
        if let panel { reposition(panel) }
    }

    // Reads window geometry from the window server (CGWindowList), not the target app's AX tree, so this
    // can never block on an unresponsive app. nil ⇒ caller keeps the panel's current screen.
    private func focusedWindowScreen() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        // Front-to-back order: the first normal (layer 0) window owned by the frontmost app is its key window.
        for info in infos {
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner == pid,
                  ((info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) == 0,
                  let boundsDict = info[kCGWindowBounds as String] else { continue }
            var quartz = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as! CFDictionary, &quartz) else { continue }
            return Self.screen(forQuartzRect: quartz)
        }
        return nil
    }

    // CGWindowList rects are top-left-origin global (Quartz); flip to AppKit's bottom-left space against the
    // primary screen, then pick the NSScreen with the largest overlap (falling back to the one under center).
    private static func screen(forQuartzRect quartz: CGRect) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? quartz.maxY
        let cocoa = CGRect(x: quartz.origin.x, y: primaryHeight - quartz.origin.y - quartz.height,
                           width: quartz.width, height: quartz.height)
        let overlap = NSScreen.screens.max { area($0.frame.intersection(cocoa)) < area($1.frame.intersection(cocoa)) }
        if let overlap, area(overlap.frame.intersection(cocoa)) > 0 { return overlap }
        let center = CGPoint(x: cocoa.midX, y: cocoa.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// A minimal flow layout: wraps to a new row when the next subview would exceed the proposed width. Used
// for the HUD's data-boundary badges so they wrap instead of clipping the fixed-width panel.
private struct WrapLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0, totalHeight: CGFloat = 0, maxRow: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                maxRow = max(maxRow, rowWidth)
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        maxRow = max(maxRow, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(maxRow, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    // Held, not observed: only the nested RecordingIcon observes it, so a level tick rebuilds that
    // subview alone, not all of `body`.
    let level: HUDLevel
    let onInsertLocalTranscript: () -> Void
    let onPasteLast: () -> Void
    let onErrorAction: (HUDErrorAction) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(primary).font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let secondary {
                        Text(secondary).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.state.dataBoundaryBadges.isEmpty {
                        // Wrap to as many rows as needed so badges never clip; each is `.fixedSize()` so a
                        // label never ellipsizes.
                        WrapLayout(spacing: 4) {
                            ForEach(model.state.dataBoundaryBadges, id: \.self) {
                                DataBoundaryBadge(label: $0).fixedSize()
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if hasAction {
                actionButtons
                    .buttonStyle(HUDActionButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 280, alignment: .leading)
        .frame(minHeight: model.state.contentHeight, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(AccessibilityID.HUD.panel)
    }

    private var hasAction: Bool {
        model.state.offersLocalTranscript || model.state.offersPasteLast || model.state.errorAction != nil
    }

    @ViewBuilder private var actionButtons: some View {
        if model.state.offersLocalTranscript {
            Button { onInsertLocalTranscript() } label: {
                Label("Insert without rewriting", systemImage: "text.insert")
            }
            .accessibilityIdentifier(AccessibilityID.HUD.insertWithoutRewriting)
        }
        if model.state.offersPasteLast {
            Button { onPasteLast() } label: {
                Label("Paste last dictation", systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier(AccessibilityID.HUD.pasteLast)
        }
        if let action = model.state.errorAction {
            Button { onErrorAction(action) } label: {
                Label(action.buttonTitle, systemImage: "gearshape")
            }
            .accessibilityIdentifier(AccessibilityID.HUD.repairAction)
        }
    }

    @ViewBuilder private var icon: some View {
        switch model.state.indicator {
        case .ready:
            Image(systemName: "mic").foregroundStyle(.secondary)
        case .preparing:
            PreparingIcon()
        case .recording:
            RecordingIcon(level: level)
        case .processing:
            ProcessingIcon()
        case .complete:
            if case .complete(let outcome, _) = model.state {
                Image(systemName: outcomeSymbol(outcome))
                    .font(.system(size: outcomeIconSize(outcome), weight: .semibold))
                    .foregroundStyle(outcomeStyle(outcome))
                    .frame(width: 30, height: 30)
            }
        case .error:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .none:
            EmptyView()
        case .warning:
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.orange)
        }
    }

    private var primary: String { model.state.primaryText ?? "" }
    private var secondary: String? { model.state.secondaryText }

    private var accessibilityLabel: String {
        var parts = [primary]
        if let secondary { parts.append(secondary) }
        if !model.state.dataBoundaryBadges.isEmpty {
            parts.append(contentsOf: model.state.dataBoundaryBadges)
        }
        return parts.joined(separator: ". ")
    }

    private func outcomeSymbol(_ outcome: DictationOutcome) -> String {
        switch outcome {
        case .inserted: return "checkmark.circle.fill"
        case .copied: return "doc.on.clipboard"
        case .noSpeech: return "mic.slash"
        case .failed: return "xmark.circle"
        }
    }

    private func outcomeStyle(_ outcome: DictationOutcome) -> AnyShapeStyle {
        switch outcome {
        case .inserted:
            return AnyShapeStyle(.green)
        case .copied:
            return AnyShapeStyle(Color.accentColor)
        case .noSpeech:
            return AnyShapeStyle(.secondary)
        case .failed:
            return AnyShapeStyle(.orange)
        }
    }

    private func outcomeIconSize(_ outcome: DictationOutcome) -> CGFloat {
        switch outcome {
        case .inserted:
            return 19
        case .copied, .noSpeech, .failed:
            return 17
        }
    }
}

private struct PreparingIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.orange.opacity(pulse ? 0.52 : 0.24), lineWidth: 2)
                .frame(width: pulse ? 30 : 24, height: pulse ? 30 : 24)
            Circle().fill(.orange.opacity(0.12))
                .frame(width: 22, height: 22)
            Image(systemName: "mic")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
        }
        .frame(width: 30, height: 30)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityLabel("Preparing dictation")
    }
}

private struct HUDActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            .brightness(configuration.isPressed ? -0.08 : 0)
    }
}

private struct ProcessingIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.08))
                .frame(width: 18, height: 18)
            Circle()
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 2)
                .frame(width: 24, height: 24)
            Circle()
                .trim(from: 0.08, to: 0.74)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color.accentColor.opacity(0.18),
                            Color.accentColor.opacity(0.95),
                            Color.white.opacity(0.72)
                        ]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                )
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(rotation ? 360 : 0))
        }
        .frame(width: 30, height: 30)
        .animation(reduceMotion ? nil : .linear(duration: 0.85).repeatForever(autoreverses: false), value: rotation)
        .onAppear { rotation = true }
        .accessibilityLabel("Processing")
    }
}

private struct RecordingIcon: View {
    @ObservedObject var level: HUDLevel
    var body: some View { LevelIndicator(level: level.level) }
}

private struct LevelIndicator: View {
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let l = CGFloat(min(1, max(0, level)))
        ZStack {
            // Reduce Motion (ui_design.md §4/§9): geometry stays fixed and the level is carried by fill
            // intensity alone — the dot must not grow/shrink per audio buffer.
            if reduceMotion {
                Circle().fill(.red.opacity(0.16 + l * 0.34)).frame(width: 30, height: 30)
                Circle().fill(.red).frame(width: 16, height: 16)
            } else {
                Circle().fill(.red.opacity(0.14 + l * 0.34))
                    .frame(width: 16 + l * 14, height: 16 + l * 14)
                Circle().fill(.red)
                    .frame(width: 7 + l * 17, height: 7 + l * 17)
            }
        }
        .frame(width: 30, height: 30)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .accessibilityLabel("Recording")
    }
}
