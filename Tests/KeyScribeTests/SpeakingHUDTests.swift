import AppKit
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct SpeakingHUDTests {
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "speaking-hud-\(UUID().uuidString)")!
    }

    @Test func theSummaryIsHiddenByDefault() {
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: scratchDefaults())
        defer { hud.hide() }
        hud.show(name: "keyscribe blue", summary: "Done.")
        #expect(!hud.showsSummary)
        #expect(hud.shownSummary == "Done.")
    }

    @Test func showingTheSummaryIsRememberedAcrossLaunches() {
        let defaults = scratchDefaults()
        let first = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults)
        first.toggleSummary()
        #expect(first.showsSummary)
        #expect(SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults).showsSummary)
        first.toggleSummary()
        #expect(!SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults).showsSummary)
    }

    @Test func theNextSummaryReplacesTheTextAndKeepsTheChoice() {
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: scratchDefaults())
        defer { hud.hide() }
        hud.show(name: "keyscribe blue", summary: "First.")
        hud.toggleSummary()
        hud.show(name: "docs", summary: "Second.")
        #expect(hud.showsSummary)
        #expect(hud.shownName == "docs")
        #expect(hud.shownSummary == "Second.")
    }

    @Test func showingOrHidingTheSummaryLeavesPlaybackAndEscapeAlone() {
        let escape = FakeChordRegistrar()
        let hud = SpeakingHUDController(escape: escape, defaults: scratchDefaults())
        defer { hud.hide() }
        var stops = 0
        hud.onStop = { stops += 1 }
        hud.show(name: "keyscribe blue", summary: "Done.")
        let registered = escape.lastRegistrations.map(\.keyCode)
        hud.toggleSummary()
        hud.toggleSummary()
        #expect(stops == 0)
        #expect(escape.lastRegistrations.map(\.keyCode) == registered)
        #expect(hud.shownName == "keyscribe blue")
        #expect(hud.panelCanBecomeKey == false)
        escape.lastRegistrations.first?.onPressed()
        #expect(stops == 1)
    }

    @Test func thePanelKeepsOneWidthWhetherOrNotTheCaptionShows() throws {
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: scratchDefaults())
        defer { hud.hide() }
        hud.show(name: "platform infrastructure migration review green", summary: "Done. The tests pass.")
        let compact = try #require(hud.panelFrame)
        hud.toggleSummary()
        let expanded = try #require(hud.panelFrame)
        #expect(compact.width == SpeakingHUDLayout.width)
        #expect(expanded.width == SpeakingHUDLayout.width)
        #expect(expanded.height > compact.height)
    }

    @Test func theDisclosureNamesItsActionAndReportsItsState() {
        #expect(SpeakingHUDLayout.disclosureLabel(showsSummary: false) == "Show spoken text")
        #expect(SpeakingHUDLayout.disclosureLabel(showsSummary: true) == "Hide spoken text")
        #expect(SpeakingHUDLayout.disclosureValue(showsSummary: false) == "Collapsed")
        #expect(SpeakingHUDLayout.disclosureValue(showsSummary: true) == "Expanded")
    }

    @Test func whenEscapeCannotBeClaimedThePanelDoesNotOfferIt() {
        let escape = FakeChordRegistrar()
        escape.refuses = true
        let hud = SpeakingHUDController(escape: escape, defaults: scratchDefaults())
        defer { hud.hide() }
        hud.show(name: "keyscribe blue", summary: "Done.")
        #expect(hud.status == "Speaking")
        let claimed = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: scratchDefaults())
        defer { claimed.hide() }
        claimed.show(name: "keyscribe blue", summary: "Done.")
        #expect(claimed.status == "Speaking \u{00B7} Esc stops playback")
    }

    @Test(arguments: [HUDAnchor.topLeft, .bottomLeft])
    func onAScreenTooShortForTheCaptionItScrollsAndKeepsClearOfTheDivider(_ anchor: HUDAnchor) throws {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 120)
        let defaults = scratchDefaults()
        HUDAnchorStore.save(anchor, defaults)
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults, visibleFrame: { _ in screen })
        defer { hud.hide() }
        hud.show(name: "keyscribe blue", summary: String(repeating: "A long sentence that keeps going. ", count: 12))
        let controls = try #require(hud.panelFrame)
        hud.toggleSummary()
        let frame = try #require(hud.panelFrame)
        #expect(screen.contains(frame))
        let content = try #require(hud.panelContentView)
        content.layoutSubtreeIfNeeded()
        let scroll = try #require(Self.first(NSScrollView.self, in: content))
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > scroll.contentView.bounds.height)
        #expect(scroll.frame.height < frame.height)
        let maximum = document.frame.height - scroll.contentView.bounds.height
        for position in [CGFloat.zero, maximum / 2, maximum] {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: position))
            scroll.reflectScrolledClipView(scroll.contentView)
            content.layoutSubtreeIfNeeded()
            let viewport = scroll.convert(scroll.bounds, to: content)
            let clearance = anchor.keepsBottomEdge == content.isFlipped
                ? content.bounds.maxY - controls.height - viewport.maxY
                : viewport.minY - content.bounds.minY - controls.height
            #expect(clearance >= 8)
            let outerClearance = anchor.keepsBottomEdge == content.isFlipped
                ? viewport.minY - content.bounds.minY
                : content.bounds.maxY - viewport.maxY
            #expect(outerClearance >= 10)
        }
    }

    private static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = first(type, in: child) { return match } }
        return nil
    }

    @Test func showingClaimsEscapeAndPressingItStops() {
        let escape = FakeChordRegistrar()
        let hud = SpeakingHUDController(escape: escape, defaults: scratchDefaults())
        defer { hud.hide() }
        var stops = 0
        hud.onStop = { stops += 1 }
        hud.show(name: "keyscribe blue", summary: "Done.")
        #expect(escape.lastRegistrations.map(\.keyCode) == [53])
        #expect(escape.lastRegistrations.first?.modifiers == [])
        escape.lastRegistrations.first?.onPressed()
        #expect(stops == 1)
    }

    @Test func escapeIsLeftAloneWhileNothingIsSpeaking() {
        let escape = FakeChordRegistrar()
        let hud = SpeakingHUDController(escape: escape, defaults: scratchDefaults())
        defer { hud.hide() }
        #expect(escape.lastRegistrations.isEmpty)
        hud.show(name: "keyscribe blue", summary: "Done.")
        hud.hide()
        #expect(escape.lastRegistrations.isEmpty)
        #expect(hud.shownName == nil)
    }

    @Test func draggingSnapsToTheNearestAnchorAndSharesItWithoutTouchingPlayback() async throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let defaults = scratchDefaults()
        HUDAnchorStore.save(.bottomCenter, defaults)
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults, visibleFrame: { _ in screen })
        defer { hud.hide() }
        var stops = 0
        var anchors: [HUDAnchor] = []
        hud.onStop = { stops += 1 }
        hud.onAnchorChange = { anchors.append($0) }
        hud.show(name: "keyscribe blue", summary: "Done.")
        hud.toggleSummary()
        let panel = try #require(hud.panel)
        try await Task.sleep(for: .milliseconds(50))
        panel.setFrameOrigin(NSPoint(x: 30, y: screen.maxY - panel.frame.height - 30))
        try await Task.sleep(for: .seconds(HUDDragSnap.settle + 0.15))
        #expect(anchors == [.topLeft])
        #expect(HUDAnchorStore.load(defaults) == .topLeft)
        #expect(stops == 0)
        #expect(hud.showsSummary)
        let placed = try #require(hud.panelFrame)
        #expect(placed.minX == screen.minX + HUDAnchor.defaultMargin)
        #expect(placed.maxY == screen.maxY - HUDAnchor.defaultMargin)
    }

    @Test func itShowsTheExactConversationNameAndNeverTakesKeyFocus() {
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: scratchDefaults())
        defer { hud.hide() }
        hud.show(name: "keyscribe blue", summary: "Done.")
        #expect(hud.shownName == "keyscribe blue")
        #expect(hud.panelCanBecomeKey == false)
    }
}

@MainActor
struct SpeakingHUDPreviewTests {
    @Test func theOverflowPreviewReproducesTheShortScreenCaptionOnlyInDevelopment() throws {
        let arguments = ["KeyScribe", "--speaking-preview", "overflow", "--speaking-expanded"]
        let preview = try #require(HUDPreview.speaking(from: arguments, isDevelopmentBuild: true))
        #expect(preview.screenHeight == 120)
        #expect(preview.summary == String(repeating: "A long sentence that keeps going. ", count: 12))
        #expect(preview.expanded)
        #expect(HUDPreview.speaking(from: arguments, isDevelopmentBuild: false) == nil)
    }
}

@MainActor
struct SpokenUpdatesMenuTests {
    @Test func theToggleAppearsWithCodingAgentsShowsTheSettingAndReportsAClick() throws {
        let menu = MenuBarController()
        menu.install()
        let item = menu.spokenUpdatesMenuItem
        #expect(item.isHidden)
        #expect(item.title == "Read Agent Replies Aloud")
        menu.setSpokenUpdates(available: true, on: true)
        #expect(!item.isHidden)
        #expect(item.isEnabled)
        #expect(item.state == .on)
        menu.setSpokenUpdates(available: true, on: false)
        #expect(item.state == .off)
        var toggles = 0
        menu.onToggleSpokenUpdates = { toggles += 1 }
        let action = try #require(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
        #expect(toggles == 1)
    }
}

@MainActor
struct SpokenUpdatesMenuAvailabilityTests {
    @Test func theItemIsHiddenWithoutCodingAgents() {
        let menu = MenuBarController()
        menu.install()
        menu.setSpokenUpdates(available: false, on: true)
        #expect(menu.spokenUpdatesMenuItem.isHidden)
    }
}

@MainActor
struct LastReplyMenuTests {
    @Test func theLastReplyItemAppearsOnceAReplyIsInHistoryAndOpensIt() throws {
        let menu = MenuBarController()
        menu.install()
        let item = menu.lastReplyMenuItem
        #expect(item.title == "Last Reply in History\u{2026}")
        #expect(item.isHidden)
        menu.setLastReply(available: true)
        #expect(!item.isHidden)
        var opened = 0
        menu.onOpenLastReply = { opened += 1 }
        let action = try #require(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
        #expect(opened == 1)
        menu.setLastReply(available: false)
        #expect(item.isHidden)
    }
}
