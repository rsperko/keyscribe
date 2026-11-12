import AppKit
import KeyScribeKit
import SwiftUI

@MainActor
final class SpeakingHUDModel: ObservableObject {
    @Published var name = ""
    @Published var caption = ""
    @Published var showsSummary = false
    @Published var status = SpeakingHUDLayout.withEscape
    @Published var captionAbove = false
    @Published var captionLimit: CGFloat?
}

@MainActor
final class SpeakingHUDController {
    static let showsSummaryKey = "speakingHUD.showsSummary"

    private let escape: EscapeClaim
    private let defaults: UserDefaults
    private let model = SpeakingHUDModel()
    private(set) var panel: HUDPanel?
    private var dragSnap: HUDDragSnap?
    private(set) var shownName: String?
    var onStop: (() -> Void)?
    var onAnchorChange: ((HUDAnchor) -> Void)?
    var appearance: HUDAppearance = .system

    private let visibleFrame: (NSPanel) -> CGRect?

    init(
        escape: any ChordRegistering = CarbonHotKeys(), defaults: UserDefaults = .standard,
        visibleFrame: @escaping (NSPanel) -> CGRect? = { ($0.screen ?? NSScreen.main)?.visibleFrame }
    ) {
        self.escape = EscapeClaim(registrar: escape)
        self.defaults = defaults
        self.visibleFrame = visibleFrame
        model.showsSummary = defaults.bool(forKey: Self.showsSummaryKey)
    }

    var panelCanBecomeKey: Bool? { panel?.canBecomeKey }
    var panelFrame: NSRect? { panel?.frame }
    var panelContentView: NSView? { panel?.contentView }
    var showsSummary: Bool { model.showsSummary }
    var status: String { model.status }
    var shownSummary: String? { shownName == nil ? nil : model.caption }

    func show(name: String, summary: String) {
        let wasHidden = shownName == nil
        shownName = name
        model.name = name
        model.caption = summary
        let panel = panel ?? makePanel()
        panel.appearance = appearance.nsAppearance()
        place(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        if wasHidden {
            let claimed = escape.claim { [weak self] in self?.onStop?() }
            model.status = claimed ? SpeakingHUDLayout.withEscape : SpeakingHUDLayout.withoutEscape
            place(panel)
            NSAccessibility.post(
                element: panel, notification: .announcementRequested,
                userInfo: [.announcement: "Speaking \(name)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    func toggleSummary() {
        model.showsSummary.toggle()
        defaults.set(model.showsSummary, forKey: Self.showsSummaryKey)
        if let panel, shownName != nil { place(panel) }
    }

    func hide() {
        guard shownName != nil else { return }
        shownName = nil
        escape.release()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: SpeakingHUDView(
            model: model, onStop: { [weak self] in self?.onStop?() }, onToggleSummary: { [weak self] in self?.toggleSummary() }))
        hosting.sizingOptions = [.intrinsicContentSize]
        let panel = HUDPanel.make(content: hosting, size: NSSize(width: SpeakingHUDLayout.width, height: 56))
        panel.allowsKey = { false }
        self.panel = panel
        dragSnap = HUDDragSnap(panel: panel) { [weak self] _ in self?.snapToNearestAnchor() }
        return panel
    }

    private func snapToNearestAnchor() {
        guard let panel, let screen = visibleFrame(panel) else { return }
        let rowHeight = NSHostingView(rootView: SpeakingRow(model: model, onStop: {}, onToggleSummary: {})).fittingSize.height
        let frame = panel.frame
        let rowCenterY = model.showsSummary && model.captionAbove ? frame.minY + rowHeight / 2 : frame.maxY - rowHeight / 2
        let anchor = HUDAnchor.nearest(
            toCenter: CGPoint(x: frame.midX, y: rowCenterY), in: screen, size: CGSize(width: frame.width, height: rowHeight))
        HUDAnchorStore.save(anchor, defaults)
        place(panel)
        onAnchorChange?(anchor)
    }

    private func place(_ panel: NSPanel) {
        guard let screen = visibleFrame(panel) else { return }
        let anchor = HUDAnchorStore.load(defaults)
        let rowSize = NSHostingView(rootView: SpeakingRow(model: model, onStop: {}, onToggleSummary: {})).fittingSize
        let captionHeight = model.showsSummary
            ? NSHostingView(rootView: SpeakingCaption(text: model.caption, above: true)).fittingSize.height : nil
        let capped = captionHeight.map { min($0, HUDAnchor.listCap(screenHeight: screen.height)) }
        let placement = anchor.placement(in: screen, header: rowSize, body: capped)
        model.captionAbove = placement.bodyAbove
        model.captionLimit = placement.body < (captionHeight ?? 0) ? placement.body : nil
        if let dragSnap {
            dragSnap.place { panel.setFrame(placement.panel, display: true) }
        } else {
            panel.setFrame(placement.panel, display: true)
        }
    }
}

@MainActor
enum SpeakingHUDLayout {
    static let width: CGFloat = 280
    static let padding: CGFloat = 14
    static let verticalPadding: CGFloat = 10
    static let captionGap: CGFloat = 8
    static let dividerHeight: CGFloat = 1
    static let spacing: CGFloat = 12
    static let button: CGFloat = 30
    static let chevron: CGFloat = 16
    static let withEscape = "Speaking \u{00B7} Esc stops playback"
    static let withoutEscape = "Speaking"

    static func disclosureLabel(showsSummary: Bool) -> String { showsSummary ? "Hide spoken text" : "Show spoken text" }
    static func disclosureValue(showsSummary: Bool) -> String { showsSummary ? "Expanded" : "Collapsed" }
}

private struct SpeakingHUDView: View {
    @ObservedObject var model: SpeakingHUDModel
    let onStop: () -> Void
    let onToggleSummary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.showsSummary, model.captionAbove {
                SpeakingCaption(text: model.caption, above: true, limit: model.captionLimit)
            }
            SpeakingRow(model: model, onStop: onStop, onToggleSummary: onToggleSummary)
            if model.showsSummary, !model.captionAbove {
                SpeakingCaption(text: model.caption, above: false, limit: model.captionLimit)
            }
        }
        .frame(width: SpeakingHUDLayout.width, alignment: .leading)
        .modifier(HUDCardBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speaking \(model.name)")
        .accessibilityIdentifier(AccessibilityID.HUD.speaking)
    }
}

struct SpeakingCaption: View {
    let text: String
    let above: Bool
    var limit: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            if !above { divider }
            Group {
                if let limit {
                    ScrollView(.vertical) { words }
                        .scrollIndicators(.visible)
                        .frame(height: max(0, limit - SpeakingHUDLayout.verticalPadding
                            - SpeakingHUDLayout.captionGap - SpeakingHUDLayout.dividerHeight))
                } else {
                    words
                }
            }
            .padding(above ? .top : .bottom, SpeakingHUDLayout.verticalPadding)
            .padding(above ? .bottom : .top, SpeakingHUDLayout.captionGap)
            if above { divider }
        }
        .frame(height: limit)
        .clipped()
    }

    private var divider: some View {
        Divider()
            .frame(height: SpeakingHUDLayout.dividerHeight)
            .padding(.horizontal, SpeakingHUDLayout.padding)
            .accessibilityHidden(true)
    }

    private var words: some View {
        Text(text)
            .font(.system(size: 12))
            .frame(width: SpeakingHUDLayout.width - SpeakingHUDLayout.padding * 2, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SpeakingHUDLayout.padding)
            .accessibilityIdentifier(AccessibilityID.HUD.speakingSummary)
    }
}

struct SpeakingRow: View {
    @ObservedObject var model: SpeakingHUDModel
    let onStop: () -> Void
    let onToggleSummary: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: SpeakingHUDLayout.spacing) {
            SpeakingStopButton(action: onStop)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            summaryToggle
        }
        .padding(.horizontal, SpeakingHUDLayout.padding)
        .padding(.vertical, SpeakingHUDLayout.verticalPadding)
        .frame(width: SpeakingHUDLayout.width)
    }

    private var chevronAngle: Double {
        guard model.showsSummary else { return 0 }
        return model.captionAbove ? -90 : 90
    }

    private var summaryToggle: some View {
        let label = SpeakingHUDLayout.disclosureLabel(showsSummary: model.showsSummary)
        return Button(action: onToggleSummary) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(chevronAngle))
                .foregroundStyle(.secondary)
                .frame(width: SpeakingHUDLayout.chevron, height: SpeakingHUDLayout.button)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(SpeakingHUDLayout.disclosureValue(showsSummary: model.showsSummary))
        .accessibilityIdentifier(AccessibilityID.HUD.speakingSummaryToggle)
    }
}

private struct SpeakingStopButton: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(haloOpacity))
                    .frame(width: 26, height: 26)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: bright)
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(Color.accentColor)
                    .frame(width: 16, height: 16)
            }
            .frame(width: SpeakingHUDLayout.button, height: SpeakingHUDLayout.button)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { bright = !reduceMotion }
        .onChange(of: reduceMotion) { _, reduced in bright = !reduced }
        .help("Stop speaking")
        .accessibilityLabel("Stop speaking")
        .accessibilityIdentifier(AccessibilityID.HUD.stopSpeaking)
    }

    private var haloOpacity: Double {
        reduceMotion ? 0.24 : (bright ? 0.34 : 0.14)
    }
}
