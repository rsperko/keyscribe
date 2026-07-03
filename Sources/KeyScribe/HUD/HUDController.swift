import AppKit
import CoreGraphics
import SwiftUI
import KeyScribeKit

@MainActor
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .hidden
}

// The recording level updates every audio buffer; kept on its own object so only `LevelIndicator`
// (which observes it) rebuilds per tick, not the whole HUD card. See render().
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

    // The HUD panel's CoreGraphics window id, so the focus-change guard can tell our own overlay apart
    // from the dictation target when we insert into our own window (the onboarding trial). Nil until the
    // panel is realized.
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
        // Pure per-buffer level update while already recording the same mode: push only the level so the
        // card chrome (material, badges, text, action buttons) is not rebuilt on every audio tick.
        if case .recording(let mode, let level) = state,
           case .recording(let currentMode, _) = model.state, mode == currentMode {
            levelModel.level = level
            return
        }
        guard model.state != state else { return }
        let wasHidden: Bool = { if case .hidden = model.state { return true } else { return false } }()
        if case .recording(_, let level) = state { levelModel.level = level }
        model.state = state
        if case .hidden = state {
            panel?.orderOut(nil)
        } else {
            showPanelIfNeeded()
            if let panel {
                resize(panel, to: state)
            }
            // Each dictation can target a window on a different display, so move the HUD to the screen
            // holding the focused window — it should appear where the user is dictating, not where it last
            // sat. Only on the hidden→visible edge so per-frame level updates during recording do not hop it.
            if wasHidden, let panel { reposition(panel, to: focusedWindowScreen()) }
            // HUD holds key focus across the cancellable states so ESC-to-cancel reaches it as a local
            // keystroke; the controller relinquishes momentarily around the synthetic ⌘C/⌘V.
            if state.holdsKeyFocus {
                panel?.makeKeyAndOrderFront(nil)
            } else if panel?.isKeyWindow == true {
                relinquishKeyFocus()
            } else {
                panel?.orderFrontRegardless()
            }
        }
    }

    // Build the panel and host view ahead of the first dictation so the first `.recording` render
    // shows instantly instead of paying NSHostingView + window realization on the hot path. Never
    // orders the panel on screen — render() does that once state leaves .hidden.
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
        let size = CGSize(width: Self.panelWidth, height: state.contentHeight)
        guard panel.frame.size != size else { return }
        isRepositioning = true
        let screen = panel.screen ?? NSScreen.main
        let origin = screen.map { anchor.origin(in: $0.visibleFrame, size: size) } ?? panel.frame.origin
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.isRepositioning = false }
        }
    }

    func relinquishKeyFocus() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    private func installLocalKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.canCancel?() == true else { return event }
            self.onEscapeCancel?()
            return nil
        }
    }

    // Restore the parked anchor on `screen` (defaults to the panel's current screen). Anchors are
    // resolution-independent — recomputed from visibleFrame each time — so a saved spot lands correctly on
    // any display; only the screen changes when the HUD follows the focused window across monitors.
    private func reposition(_ panel: NSPanel, to screen: NSScreen? = nil) {
        guard let screen = screen ?? panel.screen ?? NSScreen.main else { return }
        let origin = anchor.origin(in: screen.visibleFrame, size: panel.frame.size)
        // Our own setFrameOrigin posts didMove; guard so it isn't mistaken for a user drag. The flag is
        // cleared a runloop tick later because the queued notification fires asynchronously.
        isRepositioning = true
        panel.setFrameOrigin(origin)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.isRepositioning = false }
        }
    }

    // The panel is draggable by its background; on each move, debounce until the drag settles, then snap
    // to the nearest of the eight anchors and persist it.
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

    // The screen holding the frontmost app's focused window, so the HUD shows on the display being
    // dictated into. Reads window geometry from the window server (CGWindowList), NOT the target app's AX
    // tree, so it can never block on an unresponsive app. nil ⇒ caller keeps the panel's current screen.
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

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    // Held, not observed: only the nested RecordingIcon observes it, so a level tick rebuilds that
    // subview alone and leaves the rest of `body` untouched.
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
                    if let secondary {
                        Text(secondary).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !model.state.dataBoundaryBadges.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(model.state.dataBoundaryBadges, id: \.self) { DataBoundaryBadge(label: $0) }
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
        .frame(width: 280, height: model.state.contentHeight, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var hasAction: Bool {
        model.state.offersLocalTranscript || model.state.offersPasteLast || model.state.errorAction != nil
    }

    @ViewBuilder private var actionButtons: some View {
        if model.state.offersLocalTranscript {
            Button { onInsertLocalTranscript() } label: {
                Label("Insert without rewriting", systemImage: "text.insert")
            }
        }
        if model.state.offersPasteLast {
            Button { onPasteLast() } label: {
                Label("Paste last dictation", systemImage: "doc.on.clipboard")
            }
        }
        if let action = model.state.errorAction {
            Button { onErrorAction(action) } label: {
                Label(action.buttonTitle, systemImage: "gearshape")
            }
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
                .frame(width: 22, height: 22)
            Circle()
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 2)
                .frame(width: 28, height: 28)
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
                .frame(width: 28, height: 28)
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
            Circle().fill(.red.opacity(0.14 + l * 0.34))
                .frame(width: 16 + l * 14, height: 16 + l * 14)
            Circle().fill(.red)
                .frame(width: 7 + l * 17, height: 7 + l * 17)
        }
        .frame(width: 30, height: 30)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .accessibilityLabel("Recording")
    }
}
