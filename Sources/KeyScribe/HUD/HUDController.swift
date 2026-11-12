import AppKit
import CoreGraphics
import SwiftUI
import KeyScribeKit

@MainActor
final class HUDModel: ObservableObject {
    var state: HUDState = .hidden {
        didSet {
            switch (oldValue, state) {
            case (.recording, .recording): break
            case (_, .recording): recordingAdmission += 1
            default: break
            }
            if state != .hidden { shown = state }
        }
    }
    @Published private(set) var recordingAdmission = 0
    // What the card draws. Hiding keeps the last card so the panel fades out whole; redrawing it as hidden
    // mid-fade dropped the card's background while the buttons' bezels lingered.
    @Published private(set) var shown: HUDState = .hidden
    @Published var screenHeight: CGFloat = 800
    @Published var listAbove = HUDAnchor.default.keepsBottomEdge
}

// Kept separate from HUDModel so only `LevelIndicator` rebuilds on each per-buffer level tick, not
// the whole HUD card (see render()).
@MainActor
final class HUDLevel: ObservableObject {
    @Published var level: Float = 0
}

@MainActor
final class HUDController: HUDPresenting {
    private let model = HUDModel()
    private let levelModel = HUDLevel()
    private var panel: NSPanel?
    var panelAppearance: NSAppearance? { panel?.appearance }
    var appearance: HUDAppearance = .system {
        didSet { if appearance != oldValue { applyAppearance() } }
    }

    // Lets the focus-change guard distinguish our own overlay from the dictation target when inserting
    // into our own window (the onboarding trial). Nil until the panel is realized.
    var hudWindowID: CGWindowID? {
        guard let number = panel?.windowNumber, number > 0 else { return nil }
        return CGWindowID(number)
    }
    var onInsertLocalTranscript: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onOpenSpeechModels: (() -> Void)?
    var onOpenAIService: ((String) -> Void)?
    var onOpenCodingAgents: ((String, [String]) -> Void)?
    var onEscapeCancel: (() -> Void)?
    var onChooseVoiceCommand: ((Int, String) -> Void)?
    var onCancelVoiceCommandChoice: ((Int) -> Void)?
    var onCloseHelp: (() -> Void)?
    var onHelpHover: ((Bool) -> Void)?
    var canCancel: (() -> Bool)?
    var onVisibilityChange: ((Bool) -> Void)?
    private var localKeyMonitor: Any?
    private let defaults: UserDefaults
    private var anchor: HUDAnchor
    var currentAnchor: HUDAnchor { anchor }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        anchor = HUDAnchorStore.load(defaults)
    }
    private var dragSnap: HUDDragSnap?

    func render(_ state: HUDState) {
        // Same mode/latch, only the level changed: push just the level so the card chrome isn't rebuilt
        // on every audio tick.
        if case .recording(let mode, let level, let latched, let countdown, let agents) = state,
           case .recording(let currentMode, _, let currentLatched, let currentCountdown, let currentAgents) = model.state,
           mode == currentMode, latched == currentLatched, agents == currentAgents {
            levelModel.level = level
            if countdown != currentCountdown {
                model.state = state
                if let panel { resize(panel, to: state) }
                if currentCountdown == nil { announce(state) }
            }
            return
        }
        if case .choice(let prompt, .listening(let latched), let level) = state,
           case .choice(let current, .listening(let currentLatched), _) = model.state,
           prompt == current, latched == currentLatched {
            levelModel.level = level
            return
        }
        guard model.state != state else { return }
        let previous = model.state
        let wasHidden: Bool = { if case .hidden = previous { return true } else { return false } }()
        if case .recording(_, let level, _, _, _) = state {
            levelModel.level = level
        }
        if case .choice(_, .listening, let level) = state {
            levelModel.level = level
        }
        model.state = state
        announce(state, after: previous)
        let isHidden: Bool = { if case .hidden = state { return true } else { return false } }()
        if isHidden != wasHidden { onVisibilityChange?(!isHidden) }
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
            if wasHidden, let panel { reposition(panel, to: placementScreen()) }
            // Re-resolved per appearance rather than observed, so Opposite tracks a system flip from the next
            // dictation on.
            if wasHidden { applyAppearance() }
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
        model.listAbove = anchor.keepsBottomEdge
        let hosting = NSHostingView(rootView: HUDView(
            model: model,
            level: levelModel,
            onInsertLocalTranscript: { [weak self] in self?.onInsertLocalTranscript?() },
            onPasteLast: { [weak self] in self?.onPasteLast?() },
            onErrorAction: { [weak self] action in
                switch action {
                case .openMicrophoneSettings: Permissions.openSettings(.microphone)
                case .openAccessibilitySettings: Permissions.openSettings(.accessibility)
                case .openAutomationSettings: Permissions.openSettings(.automation)
                case .openSpeechModels: self?.onOpenSpeechModels?()
                case .openAIService(let id): self?.onOpenAIService?(id)
                case .openCodingAgents(let mode, let rows): self?.onOpenCodingAgents?(mode, rows)
                }
            },
            onChoose: { [weak self] id, identity in self?.onChooseVoiceCommand?(id, identity) },
            onCancelChoice: { [weak self] id in self?.onCancelVoiceCommandChoice?(id) },
            onCloseHelp: { [weak self] in self?.onCloseHelp?() },
            onHelpHover: { [weak self] hovering in self?.onHelpHover?(hovering) }))
        // Let the panel grow to the content's intrinsic height (badges wrap, text never ellipsizes); the
        // width comes from the state. `resize` reads fittingSize and grows upward.
        hosting.sizingOptions = [.intrinsicContentSize]
        let panel = HUDPanel.make(
            content: hosting, size: NSSize(width: HUDState.hidden.panelWidth, height: HUDState.hidden.contentHeight))
        // Only a recording or cancellable HUD may be key, even when clicked.
        panel.allowsKey = { [weak self] in self?.model.state.holdsKeyFocus == true }
        self.panel = panel
        dragSnap = HUDDragSnap(panel: panel) { [weak self] _ in self?.snapToNearestAnchor() }
        reposition(panel)
        applyAppearance()
        installLocalKeyMonitor()
    }

    private func applyAppearance() {
        panel?.appearance = appearance.nsAppearance()
    }

    private func resize(_ panel: NSPanel, to state: HUDState) {
        // contentHeight is a floor; take the max with the hosting view's actual fitting height. Force a
        // layout pass first — `model.state` was just mutated and SwiftUI may not have reconciled the
        // hosting view yet, so a cold `fittingSize` read can return the previous (smaller) state's height
        // and clip a wrap-grown state on a state→state transition.
        if let screen = panel.screen ?? NSScreen.main, model.screenHeight != screen.visibleFrame.height {
            model.screenHeight = screen.visibleFrame.height
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        let fittingHeight = panel.contentView?.fittingSize.height ?? 0
        let height = max(state.contentHeight, fittingHeight)
        let size = CGSize(width: state.panelWidth, height: height)
        guard panel.frame.size != size else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        apply(Self.placement(of: state, size: size, in: screen.visibleFrame, anchor: anchor), to: panel)
    }

    static func placement(of state: HUDState, size: CGSize, in screen: CGRect, anchor: HUDAnchor) -> HUDPlacement {
        guard state.hasList else { return anchor.placement(in: screen, header: size, body: nil) }
        let header = CGSize(width: size.width, height: HUDState.listHeaderExtent)
        return anchor.placement(in: screen, header: header, body: max(0, size.height - header.height))
    }

    private func apply(_ placement: HUDPlacement, to panel: NSPanel) {
        if model.listAbove != placement.bodyAbove { model.listAbove = placement.bodyAbove }
        place { panel.setFrame(placement.panel, display: true) }
    }

    // The HUD panel is non-activating and usually not the focused element, so a changed accessibilityLabel
    // isn't read automatically — an explicit announcement is the only reliable VoiceOver cue for a state
    // change (ui_design.md §9). Level ticks never reach here (render early-returns on those).
    private func announce(_ state: HUDState, after previous: HUDState? = nil) {
        guard let text = previous.map(state.voiceOverAnnouncement(after:)) ?? state.voiceOverAnnouncement,
              !text.isEmpty else { return }
        let element: Any = panel ?? NSApp as Any
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    var panelCanBecomeKey: Bool { panel?.canBecomeKey ?? false }
    var panelFrame: NSRect? { panel?.frame }
    var panelContentView: NSView? { panel?.contentView }

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

    static func tookKey(eventWindow: NSWindow?, panel: NSWindow?) -> Bool {
        eventWindow == nil || eventWindow === panel
    }

    var onKeyTaken: ((CGEvent) -> Void)?

    private func installLocalKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53, self.canCancel?() == true {
                self.onEscapeCancel?()
                return nil
            }
            if Self.tookKey(eventWindow: event.window, panel: self.panel), let cgEvent = event.cgEvent {
                self.onKeyTaken?(cgEvent)
            }
            return event
        }
    }

    // Anchors are resolution-independent — recomputed from visibleFrame each time — so a saved spot lands
    // correctly on any display; only the screen changes when the HUD follows the focused window.
    private func reposition(_ panel: NSPanel, to screen: NSScreen? = nil) {
        guard let screen = screen ?? panel.screen ?? NSScreen.main else { return }
        if model.screenHeight != screen.visibleFrame.height { model.screenHeight = screen.visibleFrame.height }
        apply(Self.placement(of: model.state, size: panel.frame.size, in: screen.visibleFrame, anchor: anchor), to: panel)
    }

    private func place(_ change: () -> Void) {
        if let dragSnap { dragSnap.place(change) } else { change() }
    }

    private func snapToNearestAnchor() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        var header = panel.frame
        if model.state.hasList {
            header.size.height = HUDState.listHeaderExtent
            if !model.listAbove { header.origin.y = panel.frame.maxY - header.height }
        }
        setAnchor(HUDAnchor.nearest(toCenter: CGPoint(x: header.midX, y: header.midY), in: screen.visibleFrame, size: header.size))
    }

    func resetAnchor() { setAnchor(.default) }

    func setAnchor(_ anchor: HUDAnchor) {
        self.anchor = anchor
        HUDAnchorStore.save(anchor, defaults)
        if let panel { reposition(panel) }
    }

    func placementScreen() -> NSScreen? {
        focusedWindowScreen() ?? panel?.screen ?? NSScreen.main
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

// A minimal flow layout: wraps to a new row when the next subview would exceed the proposed width. Used
// for the HUD's data-boundary badges so they wrap instead of clipping the fixed-width panel.
private struct VerticalStack: Layout {
    var spacing: CGFloat
    var reversed: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        let height = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in reversed ? Array(subviews.reversed()) : Array(subviews) {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height + spacing
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
    let onChoose: (Int, String) -> Void
    let onCancelChoice: (Int) -> Void
    let onCloseHelp: () -> Void
    let onHelpHover: (Bool) -> Void

    var body: some View {
        if case .choice(let prompt, _, _) = model.shown {
            card(choiceBody(prompt))
        } else if let help = model.shown.spokenHelp {
            card(helpBody(help)).onHover(perform: onHelpHover)
        } else {
            card(standardBody)
        }
    }

    private func card(_ content: some View) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: model.shown.panelWidth, alignment: .leading)
            .frame(minHeight: model.shown.contentHeight, alignment: .leading)
            .modifier(HUDCardBackground())
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(AccessibilityID.HUD.panel)
    }

    private func choiceBody(_ prompt: VoiceCommandChoicePrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(alignment: .leading, spacing: 2) {
                ForEach(prompt.rows, id: \.identity) { row in
                    Button { onChoose(prompt.id, row.identity) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(row.number)")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .frame(minWidth: 14, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name).font(.system(size: 13))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4).padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HUDChoiceRowButtonStyle())
                    .accessibilityLabel("\(row.number), \(row.name), \(row.detail)")
                    .accessibilityIdentifier(AccessibilityID.HUD.choiceRow)
                }
            }
            Text(prompt.hint).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let action = model.shown.errorAction {
                    Button { onErrorAction(action) } label: {
                        Label(action.buttonTitle, systemImage: "gearshape")
                    }
                    .accessibilityIdentifier(AccessibilityID.HUD.repairAction)
                }
                Button { onCancelChoice(prompt.id) } label: { Text("Cancel") }
                    .accessibilityIdentifier(AccessibilityID.HUD.choiceCancel)
            }
            .buttonStyle(HUDActionButtonStyle())
        }
    }

    private func helpBody(_ help: SpokenHelp) -> some View {
        VerticalStack(spacing: 10, reversed: model.listAbove) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(primary).font(.system(size: 13, weight: .semibold))
                    if let secondary { secondaryText(secondary) }
                }
                Spacer(minLength: 0)
                Button(action: onCloseHelp) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier(AccessibilityID.HUD.helpClose)
            }
            .frame(minHeight: HUDState.listHeaderHeight)
            helpList(help)
        }
    }

    private func helpList(_ help: SpokenHelp) -> some View {
        let list = VStack(alignment: .leading, spacing: HUDState.helpRowSpacing) {
            ForEach(Array(help.rows.enumerated()), id: \.offset) { helpRow($0.element) }
            if !help.suffixes.isEmpty {
                Text(SpokenHelp.suffixHeading)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.top, HUDState.helpGroupGap)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(help.suffixes.enumerated()), id: \.offset) { helpRow($0.element) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        return VStack(alignment: .leading, spacing: 6) {
            if let status = help.status {
                Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let height = HUDState.helpListHeight(help, screenHeight: model.screenHeight) {
                ScrollView(.vertical) { list.padding(.trailing, HUDState.helpScrollGutter) }
                    .frame(height: height)
                    .padding(.trailing, -HUDState.helpScrollGutter)
            } else if !help.rows.isEmpty || !help.suffixes.isEmpty {
                list
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func helpRow(_ row: SpokenHelp.Row) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.said).font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(HUDState.helpDetail(row))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.HUD.helpRow)
    }

    private var header: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(primary).font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let secondary { secondaryText(secondary) }
            }
            Spacer(minLength: 0)
        }
    }

    private func secondaryText(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .lineLimit(model.shown.secondaryIsHeardExcerpt ? 2 : nil)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var standardBody: some View {
        VStack(spacing: 8) {
            if let agents = model.shown.agentRoster {
                VerticalStack(spacing: 8, reversed: model.listAbove) {
                    standardHeader.frame(minHeight: HUDState.listHeaderHeight)
                    agentList(agents)
                }
            } else {
                standardHeader
            }
            if hasAction {
                HStack(spacing: 8) { actionButtons }
                    .buttonStyle(HUDActionButtonStyle())
            }
        }
    }

    private var standardHeader: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(primary).font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let secondary { secondaryText(secondary) }
                if !model.shown.dataBoundaryBadges.isEmpty {
                    // Wrap to as many rows as needed so badges never clip; each is `.fixedSize()` so a
                    // label never ellipsizes.
                    WrapLayout(spacing: 4) {
                        ForEach(model.shown.dataBoundaryBadges, id: \.self) {
                            DataBoundaryBadge(label: $0).fixedSize()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func scrollToRecipient(_ agents: AgentRoster, _ proxy: ScrollViewProxy) {
        if let current = agents.rows.first(where: \.current) { proxy.scrollTo(current.id, anchor: .center) }
    }

    private func agentList(_ agents: AgentRoster) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let height = HUDState.agentListHeight(rows: agents.rows.count, screenHeight: model.screenHeight) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { agentRows(agents) }
                        .frame(height: height)
                        .onChange(of: model.recordingAdmission, initial: true) { _, _ in scrollToRecipient(agents, proxy) }
                        .onChange(of: agents.rows.first(where: \.current)?.id) { _, _ in scrollToRecipient(agents, proxy) }
                }
            } else if !agents.rows.isEmpty {
                agentRows(agents)
            }
            if let hint = model.shown.agentRosterHint {
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func agentRows(_ agents: AgentRoster) -> some View {
        VStack(alignment: .leading, spacing: HUDState.agentRowStep - HUDState.agentRowHeight) {
            ForEach(agents.rows, id: \.id) { agentRow($0).id($0.id) }
        }
    }

    private func agentRow(_ row: AgentRoster.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(row.number)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(minWidth: 14, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 13, weight: row.current ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(row.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if row.current {
                        Text("Current").fontWeight(.medium).fixedSize()
                    }
                }
                .font(.system(size: 11))
            }
            Spacer(minLength: 8)
            Text(row.state).font(.system(size: 11))
                .foregroundStyle(row.available ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: HUDState.agentRowHeight, maxHeight: HUDState.agentRowHeight, alignment: .leading)
        .background(row.current ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HUDState.spoken(row))
        .accessibilityIdentifier(AccessibilityID.HUD.agentRow)
    }

    private var hasAction: Bool {
        model.shown.offersLocalTranscript || model.shown.offersPasteLast || model.shown.errorAction != nil
    }

    @ViewBuilder private var actionButtons: some View {
        if model.shown.offersLocalTranscript {
            Button { onInsertLocalTranscript() } label: {
                Label("Insert without rewriting", systemImage: "text.insert")
            }
            .accessibilityIdentifier(AccessibilityID.HUD.insertWithoutRewriting)
        }
        if model.shown.offersPasteLast {
            Button { onPasteLast() } label: {
                Label("Paste last dictation", systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier(AccessibilityID.HUD.pasteLast)
        }
        if let action = model.shown.errorAction {
            Button { onErrorAction(action) } label: {
                Label(action.buttonTitle, systemImage: "gearshape")
            }
            .accessibilityIdentifier(AccessibilityID.HUD.repairAction)
        }
    }

    @ViewBuilder private var icon: some View {
        switch model.shown.indicator {
        case .ready:
            Image(systemName: "mic").foregroundStyle(.secondary)
        case .choice:
            Image(systemName: "list.number")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        case .preparing:
            PreparingIcon()
        case .recording:
            RecordingIcon(level: level, countdown: model.shown.recordingCountdown)
        case .processing:
            ProcessingIcon()
        case .complete:
            if case .complete(let outcome, _, _, _) = model.shown {
                Image(systemName: outcomeSymbol(outcome))
                    .font(.system(size: outcomeIconSize(outcome), weight: .semibold))
                    .foregroundStyle(outcomeStyle(outcome))
                    .frame(width: 30, height: 30)
            } else if case .commandDone = model.shown {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 30, height: 30)
            }
        case .error:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .advisory:
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        case .help:
            Image(systemName: "info.circle")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        case .none:
            EmptyView()
        case .warning:
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.orange)
        case .limit:
            Image(systemName: "timer").foregroundStyle(.orange)
        case .skipped:
            if case .rewriteSkipped(let outcome, _, _) = model.shown, case .copied = outcome {
                Image(systemName: outcomeSymbol(outcome))
                    .font(.system(size: outcomeIconSize(outcome), weight: .semibold))
                    .foregroundStyle(outcomeStyle(outcome))
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: "forward.end.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
        }
    }

    private var primary: String { model.shown.primaryText ?? "" }
    private var secondary: String? { model.shown.secondaryText }

    private var accessibilityLabel: String {
        var parts = [primary]
        if let secondary { parts.append(secondary) }
        if !model.shown.dataBoundaryBadges.isEmpty {
            parts.append(contentsOf: model.shown.dataBoundaryBadges)
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
        .accessibilityLabel("Loading speech model")
    }
}

private struct HUDChoiceRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 7))
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
    @Environment(\.colorScheme) private var colorScheme
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
                            colorScheme == .dark ? Color.white.opacity(0.72) : Color.accentColor.opacity(0.55)
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
    let countdown: RecordingCountdown?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LevelIndicator(level: level.level)
            if let countdown {
                Circle()
                    .trim(from: 0, to: countdown.fractionLeft)
                    .stroke(.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 29, height: 29)
                    .animation(reduceMotion ? nil : .linear(duration: 1), value: countdown.fractionLeft)
            }
        }
        .frame(width: 30, height: 30)
    }
}

private struct LevelIndicator: View {
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let l = CGFloat(min(1, max(0, level)))
        let tint = Color.recording(in: colorScheme)
        ZStack {
            // Reduce Motion (ui_design.md §4/§9): geometry stays fixed and the level is carried by fill
            // intensity alone — the dot must not grow/shrink per audio buffer.
            if reduceMotion {
                Circle().fill(tint.opacity(0.16 + l * 0.34)).frame(width: 30, height: 30)
                Circle().fill(tint).frame(width: 16, height: 16)
            } else {
                Circle().fill(tint.opacity(0.14 + l * 0.34))
                    .frame(width: 16 + l * 14, height: 16 + l * 14)
                Circle().fill(tint)
                    .frame(width: 7 + l * 17, height: 7 + l * 17)
            }
        }
        .frame(width: 30, height: 30)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .accessibilityLabel("Recording")
    }
}
