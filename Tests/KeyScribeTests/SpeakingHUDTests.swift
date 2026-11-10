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
        #expect(claimed.status == "Speaking \u{00B7} Esc to stop")
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
struct SpeakingHUDPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let row = CGSize(width: SpeakingHUDLayout.width, height: 52)

    @Test(arguments: HUDAnchor.allCases)
    func expandingNeverMovesTheControlRow(_ anchor: HUDAnchor) {
        let compact = SpeakingHUDLayout.placement(anchor: anchor, screen: screen, rowSize: row, captionHeight: nil)
        let expanded = SpeakingHUDLayout.placement(anchor: anchor, screen: screen, rowSize: row, captionHeight: 90)
        #expect(compact.panel == compact.row)
        #expect(expanded.row == compact.row)
        #expect(expanded.panel.width == SpeakingHUDLayout.width)
        #expect(expanded.panel.height == row.height + 90)
        #expect(screen.contains(expanded.panel))
        #expect(expanded.panel.contains(expanded.row))
    }

    @Test(arguments: HUDAnchor.allCases)
    func theCaptionOpensAwayFromTheAnchoredEdge(_ anchor: HUDAnchor) {
        let expanded = SpeakingHUDLayout.placement(anchor: anchor, screen: screen, rowSize: row, captionHeight: 90)
        #expect(expanded.captionAbove == anchor.keepsBottomEdge)
    }

    @Test func aCenterAnchorOpensAboveOnlyWhenBelowCannotFit() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 200)
        let fits = SpeakingHUDLayout.placement(anchor: .centerLeft, screen: screen, rowSize: row, captionHeight: 90)
        #expect(!fits.captionAbove)
        let tight = SpeakingHUDLayout.placement(anchor: .centerLeft, screen: short, rowSize: row, captionHeight: 90)
        #expect(tight.captionAbove)
        #expect(short.contains(tight.panel))
    }

    @Test func aCaptionTooTallForTheScreenScrollsAndKeepsStopOnScreen() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 160)
        let expanded = SpeakingHUDLayout.placement(anchor: .bottomLeft, screen: short, rowSize: row, captionHeight: 120)
        #expect(short.contains(expanded.panel))
        #expect(short.contains(expanded.row))
        #expect(expanded.panel.contains(expanded.row))
        #expect(expanded.captionHeight == short.height - row.height)
        #expect(expanded.captionScrolls)
        let fits = SpeakingHUDLayout.placement(anchor: .bottomLeft, screen: screen, rowSize: row, captionHeight: 120)
        #expect(fits.captionHeight == 120)
        #expect(!fits.captionScrolls)
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
