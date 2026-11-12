import AppKit
import KeyScribeKit
import SwiftUI

@MainActor
final class SpeakingHUDModel: ObservableObject {
    @Published var name = ""
    @Published var caption = ""
    @Published var showsSummary = false
    @Published var answerMode = false
    @Published var answerOpen = true
    @Published var finished = false
    @Published var textOnly = false
    var showsCaption: Bool { answerMode ? answerOpen : showsSummary }
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
    private var escapeClaimed = false
    private var hovering = false
    private var autoClose: Task<Void, Never>?
    var readingTime: (String) -> Duration = SpeakingHUDLayout.readingTime
    var voiceOverRunning: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?
    var onCopy: (() -> Bool)?
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
    var showsSummary: Bool { model.showsCaption }
    var status: String { model.status }
    var shownSummary: String? { shownName == nil ? nil : model.caption }
    var isFinished: Bool { model.finished }
    var offersCopy: Bool { model.answerMode }

    func showText(name: String, text: String) {
        show(name: name, summary: text, answer: true, textOnly: true)
    }

    func show(name: String, summary: String, answer: Bool = false, preparing: Bool = false) {
        show(name: name, summary: summary, answer: answer, preparing: preparing, textOnly: false)
    }

    private func show(name: String, summary: String, answer: Bool, preparing: Bool = false, textOnly: Bool) {
        let wasHidden = shownName == nil
        shownName = name
        model.name = name
        model.caption = summary
        autoClose?.cancel()
        autoClose = nil
        if answer, !model.answerMode || model.finished { model.answerOpen = true }
        model.answerMode = answer
        model.finished = textOnly
        model.textOnly = textOnly
        let panel = panel ?? makePanel()
        panel.appearance = appearance.nsAppearance()
        place(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        if !escapeClaimed {
            escapeClaimed = escape.claim { [weak self] in self?.escapePressed() }
        }
        model.status = textOnly
            ? (escapeClaimed ? SpeakingHUDLayout.textOnlyWithEscape : SpeakingHUDLayout.textOnlyStatus)
            : SpeakingHUDLayout.status(preparing: preparing, escape: escapeClaimed)
        place(panel)
        if wasHidden || textOnly {
            NSAccessibility.post(
                element: panel, notification: .announcementRequested,
                userInfo: [
                    .announcement: textOnly ? "\(name): \(summary)" : "Speaking \(name)",
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
        }
        if textOnly { scheduleAutoClose() }
    }

    func speaking() {
        guard shownName != nil else { return }
        model.status = SpeakingHUDLayout.status(preparing: false, escape: escapeClaimed)
    }

    func finished() {
        guard shownName != nil else { return }
        model.finished = true
        model.status = escapeClaimed ? SpeakingHUDLayout.finishedWithEscape : SpeakingHUDLayout.finishedStatus
        scheduleAutoClose()
    }

    func hover(_ inside: Bool) {
        hovering = inside
        if inside {
            autoClose?.cancel()
            autoClose = nil
        } else {
            scheduleAutoClose()
        }
    }

    private func scheduleAutoClose() {
        autoClose?.cancel()
        autoClose = nil
        guard shownName != nil, model.finished, !hovering, !voiceOverRunning() else { return }
        let delay = readingTime(model.caption)
        autoClose = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.model.finished, !self.hovering else { return }
            self.autoClose = nil
            self.close()
        }
    }

    func close() { onClose?() }

    func copy() -> Bool { onCopy?() ?? false }

    private func escapePressed() {
        if model.finished { close() } else { onStop?() }
    }

    func toggleSummary() {
        if model.answerMode {
            model.answerOpen.toggle()
            if let panel, shownName != nil { place(panel) }
            return
        }
        model.showsSummary.toggle()
        defaults.set(model.showsSummary, forKey: Self.showsSummaryKey)
        if let panel, shownName != nil { place(panel) }
    }

    func hide() {
        guard shownName != nil else { return }
        shownName = nil
        if escapeClaimed { escape.release() }
        escapeClaimed = false
        autoClose?.cancel()
        autoClose = nil
        hovering = false
        model.answerMode = false
        model.finished = false
        model.textOnly = false
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: SpeakingHUDView(
            model: model, onStop: { [weak self] in self?.onStop?() }, onToggleSummary: { [weak self] in self?.toggleSummary() },
            onClose: { [weak self] in self?.close() }, onCopy: { [weak self] in self?.copy() ?? false },
            onHover: { [weak self] in self?.hover($0) }))
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
        let rowCenterY = model.showsCaption && model.captionAbove ? frame.minY + rowHeight / 2 : frame.maxY - rowHeight / 2
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
        let captionHeight = model.showsCaption
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
    static let preparingWithEscape = "Getting ready to speak \u{00B7} Esc stops"
    static let preparingWithoutEscape = "Getting ready to speak"
    static let finishedStatus = "Finished speaking"
    static let finishedWithEscape = "Finished speaking \u{00B7} Esc closes"
    static let textOnlyStatus = "Text only"
    static let textOnlyWithEscape = "Text only \u{00B7} Esc closes"

    nonisolated static func readingTime(for text: String) -> Duration {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return .seconds(min(30, max(8, Int((Double(words) * 0.3).rounded()))))
    }

    static func status(preparing: Bool, escape: Bool) -> String {
        switch (preparing, escape) {
        case (true, true): preparingWithEscape
        case (true, false): preparingWithoutEscape
        case (false, true): withEscape
        case (false, false): withoutEscape
        }
    }

    static func disclosureLabel(showsSummary: Bool, textOnly: Bool = false) -> String {
        let text = textOnly ? "text" : "spoken text"
        return showsSummary ? "Hide \(text)" : "Show \(text)"
    }
    static func disclosureValue(showsSummary: Bool) -> String { showsSummary ? "Expanded" : "Collapsed" }
}

private struct SpeakingHUDView: View {
    @ObservedObject var model: SpeakingHUDModel
    let onStop: () -> Void
    let onToggleSummary: () -> Void
    let onClose: () -> Void
    let onCopy: () -> Bool
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.showsCaption, model.captionAbove {
                SpeakingCaption(text: model.caption, above: true, limit: model.captionLimit)
            }
            SpeakingRow(model: model, onStop: onStop, onToggleSummary: onToggleSummary, onClose: onClose, onCopy: onCopy)
            if model.showsCaption, !model.captionAbove {
                SpeakingCaption(text: model.caption, above: false, limit: model.captionLimit)
            }
        }
        .frame(width: SpeakingHUDLayout.width, alignment: .leading)
        .modifier(HUDCardBackground())
        .onHover(perform: onHover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.textOnly ? model.name : "Speaking \(model.name)")
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
    var onClose: () -> Void = {}
    var onCopy: () -> Bool = { false }

    var body: some View {
        HStack(alignment: .center, spacing: SpeakingHUDLayout.spacing) {
            if model.finished {
                SpeakingIconButton(symbol: "xmark", label: "Close", identifier: AccessibilityID.HUD.closeSpeaking, action: onClose)
            } else {
                SpeakingStopButton(action: onStop)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.answerMode {
                SpeakingCopyButton(action: onCopy)
            }
            summaryToggle
        }
        .padding(.horizontal, SpeakingHUDLayout.padding)
        .padding(.vertical, SpeakingHUDLayout.verticalPadding)
        .frame(width: SpeakingHUDLayout.width)
    }

    private var chevronAngle: Double {
        guard model.showsCaption else { return 0 }
        return model.captionAbove ? -90 : 90
    }

    private var summaryToggle: some View {
        let label = SpeakingHUDLayout.disclosureLabel(showsSummary: model.showsCaption, textOnly: model.textOnly)
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
        .accessibilityValue(SpeakingHUDLayout.disclosureValue(showsSummary: model.showsCaption))
        .accessibilityIdentifier(AccessibilityID.HUD.speakingSummaryToggle)
    }
}

private struct SpeakingIconButton: View {
    let symbol: String
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: SpeakingHUDLayout.button, height: SpeakingHUDLayout.button)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

private struct SpeakingCopyButton: View {
    let action: () -> Bool
    @State private var copied = false

    var body: some View {
        Button {
            copied = action()
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: SpeakingHUDLayout.button, height: SpeakingHUDLayout.button)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy text")
        .accessibilityLabel("Copy text")
        .accessibilityValue(copied ? "Copied" : "")
        .accessibilityIdentifier(AccessibilityID.HUD.copySpeaking)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
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
