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

    func render(_ state: HUDState) {
        guard model.state != state else { return }
        model.state = state
        if case .hidden = state {
            panel?.orderOut(nil)
        } else {
            showPanelIfNeeded()
            panel?.orderFrontRegardless()
        }
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
        let panel = NSPanel(
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

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    let onInsertLocalTranscript: () -> Void
    let onPasteLast: () -> Void
    let onErrorAction: (HUDErrorAction) -> Void

    var body: some View {
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
                if model.state.offersLocalTranscript {
                    Button("Insert local transcript") { onInsertLocalTranscript() }
                        .controlSize(.small)
                }
                if model.state.offersPasteLast {
                    Button("Paste last dictation") { onPasteLast() }
                        .controlSize(.small)
                }
                if let action = model.state.errorAction {
                    Button(action.buttonTitle) { onErrorAction(action) }
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
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

private struct LevelIndicator: View {
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(.red.opacity(0.18)).frame(width: 26, height: 26)
            Circle().fill(.red)
                .frame(width: 10 + CGFloat(level) * 12, height: 10 + CGFloat(level) * 12)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level)
        }
        .frame(width: 26, height: 26)
        .accessibilityLabel("Recording")
    }
}
