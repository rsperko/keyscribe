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
    static let escapeKeyCode = 53
    static let showsSummaryKey = "speakingHUD.showsSummary"

    private let escape: any ChordRegistering
    private let defaults: UserDefaults
    private let model = SpeakingHUDModel()
    private var panel: NSPanel?
    private(set) var shownName: String?
    var onStop: (() -> Void)?
    var appearance: HUDAppearance = .system

    private let visibleFrame: (NSPanel) -> CGRect?

    init(
        escape: any ChordRegistering = CarbonHotKeys(), defaults: UserDefaults = .standard,
        visibleFrame: @escaping (NSPanel) -> CGRect? = { ($0.screen ?? NSScreen.main)?.visibleFrame }
    ) {
        self.escape = escape
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
            let claimed = escape.update([CarbonHotKeys.Registration(
                keyCode: Self.escapeKeyCode, modifiers: [], onPressed: { [weak self] in self?.onStop?() }, onReleased: nil)])
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
        escape.update([])
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: SpeakingHUDView(
            model: model, onStop: { [weak self] in self?.onStop?() }, onToggleSummary: { [weak self] in self?.toggleSummary() }))
        hosting.sizingOptions = [.intrinsicContentSize]
        let panel = UnkeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: SpeakingHUDLayout.width, height: 56),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func place(_ panel: NSPanel) {
        guard let screen = visibleFrame(panel) else { return }
        let anchor = HUDAnchorStore.load(defaults)
        let rowSize = NSHostingView(rootView: SpeakingRow(model: model, onStop: {}, onToggleSummary: {})).fittingSize
        let captionHeight = model.showsSummary
            ? NSHostingView(rootView: SpeakingCaption(text: model.caption, above: true)).fittingSize.height : nil
        let placement = SpeakingHUDLayout.placement(anchor: anchor, screen: screen, rowSize: rowSize, captionHeight: captionHeight)
        model.captionAbove = placement.captionAbove
        model.captionLimit = placement.captionScrolls ? placement.captionHeight : nil
        panel.setFrame(placement.panel, display: true)
    }
}

private final class UnkeyablePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
enum SpeakingHUDLayout {
    struct Placement: Equatable {
        let panel: CGRect
        let row: CGRect
        let captionAbove: Bool
        var captionHeight: CGFloat = 0
        var captionScrolls = false
    }

    static let width: CGFloat = 280
    static let padding: CGFloat = 14
    static let verticalPadding: CGFloat = 10
    static let captionGap: CGFloat = 8
    static let dividerHeight: CGFloat = 1
    static let spacing: CGFloat = 12
    static let button: CGFloat = 30
    static let chevron: CGFloat = 16
    static let withEscape = "Speaking \u{00B7} Esc to stop"
    static let withoutEscape = "Speaking"

    static func placement(anchor: HUDAnchor, screen: CGRect, rowSize: CGSize, captionHeight: CGFloat?) -> Placement {
        let row = CGRect(origin: anchor.origin(in: screen, size: rowSize), size: rowSize)
        guard let captionHeight else { return Placement(panel: row, row: row, captionAbove: false) }
        let shownCaption = min(captionHeight, max(0, screen.height - rowSize.height))
        let height = rowSize.height + shownCaption
        let above: Bool = switch anchor {
        case .bottomLeft, .bottomCenter, .bottomRight: true
        case .topLeft, .topCenter, .topRight: false
        case .centerLeft, .centerRight: row.maxY - height < screen.minY
        }
        let preferredY = above ? row.minY : row.maxY - height
        let y = min(max(preferredY, screen.minY), screen.maxY - height)
        let panel = CGRect(x: row.minX, y: y, width: rowSize.width, height: height)
        let rowY = above ? panel.minY : panel.maxY - rowSize.height
        return Placement(
            panel: panel, row: CGRect(x: row.minX, y: rowY, width: rowSize.width, height: rowSize.height), captionAbove: above,
            captionHeight: shownCaption, captionScrolls: shownCaption < captionHeight)
    }

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
