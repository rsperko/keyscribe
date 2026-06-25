import AppKit
import SwiftUI
import KeyScribeKit

@MainActor
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .hidden
}

@MainActor
final class HUDController: HUDPresenting {
    private let model = HUDModel()
    private var panel: NSPanel?
    var onInsertLocalTranscript: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onEscapeCancel: (() -> Void)?
    var canCancel: (() -> Bool)?
    private var localKeyMonitor: Any?

    func render(_ state: HUDState) {
        guard model.state != state else { return }
        model.state = state
        if case .hidden = state {
            panel?.orderOut(nil)
        } else {
            showPanelIfNeeded()
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
            onInsertLocalTranscript: { [weak self] in self?.onInsertLocalTranscript?() },
            onPasteLast: { [weak self] in self?.onPasteLast?() },
            onErrorAction: { action in
                switch action {
                case .openMicrophoneSettings: Permissions.openSettings(.microphone)
                case .openAccessibilitySettings: Permissions.openSettings(.accessibility)
                }
            }))
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 92),
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
        positionAtBottomCenter(panel)
        self.panel = panel
        installLocalKeyMonitor()
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

    private func positionAtBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 80))
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    let onInsertLocalTranscript: () -> Void
    let onPasteLast: () -> Void
    let onErrorAction: (HUDErrorAction) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(primary).font(.system(size: 13, weight: .semibold))
                    if !model.state.dataBoundaryBadges.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(model.state.dataBoundaryBadges, id: \.self) { DataBoundaryBadge(label: $0) }
                        }
                    } else if let secondary {
                        Text(secondary).font(.system(size: 11)).foregroundStyle(.secondary)
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
        .frame(width: 280, height: hasAction ? 92 : 64, alignment: .leading)
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
        switch model.state {
        case .ready:
            Image(systemName: "mic").foregroundStyle(.secondary)
        case .recording(_, let level):
            LevelIndicator(level: level)
        case .transcribing, .rewriting:
            ProgressView().controlSize(.small)
        case .complete(let outcome, _):
            Image(systemName: outcomeSymbol(outcome)).foregroundStyle(.secondary)
        case .error:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .hidden:
            EmptyView()
        case .localFallback:
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.orange)
        }
    }

    private var primary: String { model.state.primaryText ?? "" }
    private var secondary: String? { model.state.secondaryText }

    private var accessibilityLabel: String {
        [primary, secondary].compactMap { $0 }.joined(separator: ". ")
    }

    private func outcomeSymbol(_ outcome: DictationOutcome) -> String {
        switch outcome {
        case .inserted: return "checkmark.circle"
        case .copied: return "doc.on.clipboard"
        case .noSpeech: return "mic.slash"
        case .failed: return "xmark.circle"
        }
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
