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
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: scratchDefaults(), displays: .unfocused)
        defer { hud.hide() }
        hud.show(name: "keyscribe blue", summary: "Done.")
        #expect(!hud.showsSummary)
        #expect(hud.shownSummary == "Done.")
    }

    @Test func anAnswerShowsItsTextAtOnceWithoutChangingTheRememberedChoice() {
        let defaults = scratchDefaults()
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults, displays: .unfocused)
        hud.show(name: "Ask About Selection", summary: "Reply by Friday.", answer: true, preparing: true)
        #expect(hud.showsSummary)
        #expect(hud.status == SpeakingHUDLayout.preparingWithEscape)
        hud.speaking()
        #expect(hud.status == SpeakingHUDLayout.withEscape)
        hud.hide()
        #expect(!hud.showsSummary)
        #expect(!SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults, displays: .unfocused).showsSummary)
    }

    @Test func collapsingAnAnswerLeavesTheRememberedChoiceAlone() {
        let defaults = scratchDefaults()
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults, displays: .unfocused)
        defer { hud.hide() }
        hud.show(name: "Ask", summary: "Reply by Friday.", answer: true, preparing: true)
        hud.toggleSummary()
        #expect(!hud.showsSummary)
        hud.toggleSummary()
        #expect(hud.showsSummary)
        hud.hide()
        hud.show(name: "backend", summary: "Done.")
        #expect(!hud.showsSummary)
        #expect(!SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults, displays: .unfocused).showsSummary)
    }

    @Test func aFinishedAnswerStaysWithItsTextAndEscapeClosesIt() {
        let escape = FakeChordRegistrar()
        let hud = SpeakingHUDController(escape: escape, defaults: scratchDefaults(), displays: .unfocused)
        defer { hud.hide() }
        var closed = 0
        var copied = 0
        hud.onClose = { closed += 1 }
        var stopped = 0
        hud.onStop = { stopped += 1 }
        hud.onCopy = { copied += 1; return true }
        hud.show(name: "Ask", summary: "Reply by Friday.", answer: true, preparing: true)
        escape.lastRegistrations.first?.onPressed()
        #expect(stopped == 1)
        #expect(closed == 0)
        hud.finished()
        #expect(hud.shownName == "Ask")
        #expect(hud.shownSummary == "Reply by Friday.")
        #expect(hud.showsSummary)
        #expect(hud.isFinished)
        #expect(hud.status == SpeakingHUDLayout.finishedWithEscape)
        escape.lastRegistrations.first?.onPressed()
        #expect(closed == 1)
        #expect(stopped == 1)
        #expect(hud.copy())
        #expect(copied == 1)
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func answerPanel(readingTime: Duration = .milliseconds(50), voiceOver: Bool = false) -> (SpeakingHUDController, () -> Int) {
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: scratchDefaults(), displays: .unfocused)
        hud.readingTime = { _ in readingTime }
        hud.voiceOverRunning = { voiceOver }
        var closed = 0
        hud.onClose = { closed += 1 }
        hud.show(name: "Ask", summary: "Reply by Friday.", answer: true, preparing: true)
        return (hud, { closed })
    }

    @Test func aFinishedAnswerClosesItselfAfterTimeToReadIt() async {
        let (hud, closed) = answerPanel()
        defer { hud.hide() }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(closed() == 0)
        hud.finished()
        await settle { closed() == 1 }
        #expect(closed() == 1)
    }

    @Test func hoveringHoldsAFinishedAnswerUntilThePointerLeaves() async {
        let (hud, closed) = answerPanel()
        defer { hud.hide() }
        hud.finished()
        hud.hover(true)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(closed() == 0)
        hud.hover(false)
        await settle { closed() == 1 }
        #expect(closed() == 1)
    }

    @Test func underVoiceOverAFinishedAnswerWaitsToBeClosed() async {
        let (hud, closed) = answerPanel(voiceOver: true)
        defer { hud.hide() }
        hud.finished()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(closed() == 0)
    }

    @Test func aNewAnswerCancelsTheEarlierOnesCountdown() async {
        let (hud, closed) = answerPanel(readingTime: .milliseconds(80))
        defer { hud.hide() }
        hud.finished()
        hud.show(name: "Ask", summary: "Second.", answer: true, preparing: true)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(closed() == 0)
    }

    @Test func readingTimeGrowsWithTheAnswerWithinBounds() {
        #expect(SpeakingHUDLayout.readingTime(for: "Reply by Friday.") == .seconds(8))
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        #expect(SpeakingHUDLayout.readingTime(for: long) == .seconds(18))
        let huge = Array(repeating: "word", count: 400).joined(separator: " ")
        #expect(SpeakingHUDLayout.readingTime(for: huge) == .seconds(30))
    }

    @Test func aNewAnswerAfterAFinishedOneClaimsEscapeAgain() {
        let escape = FakeChordRegistrar()
        let hud = SpeakingHUDController(escape: escape, defaults: scratchDefaults(), displays: .unfocused)
        defer { hud.hide() }
        hud.show(name: "Ask", summary: "First.", answer: true, preparing: true)
        hud.finished()
        hud.show(name: "Ask", summary: "Second.", answer: true, preparing: true)
        #expect(!hud.isFinished)
        #expect(!escape.lastRegistrations.isEmpty)
        #expect(hud.status == SpeakingHUDLayout.preparingWithEscape)
    }

    @Test func aPanelAlreadyShowingTakesTheNextStatus() {
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: scratchDefaults(), displays: .unfocused)
        defer { hud.hide() }
        hud.show(name: "backend", summary: "Done.")
        hud.show(name: "Ask", summary: "Reply by Friday.", answer: true, preparing: true)
        #expect(hud.status == SpeakingHUDLayout.preparingWithEscape)
    }

    @Test func showingTheSummaryIsRememberedAcrossLaunches() {
        let defaults = scratchDefaults()
        let first = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults, displays: .unfocused)
        first.toggleSummary()
        #expect(first.showsSummary)
        #expect(SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults, displays: .unfocused).showsSummary)
        first.toggleSummary()
        #expect(!SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults, displays: .unfocused).showsSummary)
    }

    @Test func theNextSummaryReplacesTheTextAndKeepsTheChoice() {
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: scratchDefaults(), displays: .unfocused)
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
        let hud = SpeakingHUDController(escape: escape, defaults: scratchDefaults(), displays: .unfocused)
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
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: scratchDefaults(), displays: .unfocused)
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
        #expect(SpeakingHUDLayout.disclosureLabel(showsSummary: true, textOnly: true) == "Hide text")
        #expect(SpeakingHUDLayout.disclosureLabel(showsSummary: false, textOnly: true) == "Show text")
    }

    @Test func whenEscapeCannotBeClaimedThePanelDoesNotOfferIt() {
        let escape = FakeChordRegistrar()
        escape.refuses = true
        let hud = SpeakingHUDController(escape: escape, defaults: scratchDefaults(), displays: .unfocused)
        defer { hud.hide() }
        hud.show(name: "keyscribe blue", summary: "Done.")
        #expect(hud.status == "Speaking")
        let claimed = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: scratchDefaults(), displays: .unfocused)
        defer { claimed.hide() }
        claimed.show(name: "keyscribe blue", summary: "Done.")
        #expect(claimed.status == "Speaking \u{00B7} Esc stops playback")
    }

    @Test(arguments: [HUDAnchor.topLeft, .bottomLeft])
    func onAScreenTooShortForTheCaptionItScrollsAndKeepsClearOfTheDivider(_ anchor: HUDAnchor) throws {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 120)
        let defaults = scratchDefaults()
        HUDAnchorStore.save(anchor, defaults)
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults, displays: FakeDisplays.single(screen))
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
        let hud = SpeakingHUDController(escape: escape, defaults: scratchDefaults(), displays: .unfocused)
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
        let hud = SpeakingHUDController(escape: escape, defaults: scratchDefaults(), displays: .unfocused)
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
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults, displays: FakeDisplays.single(screen))
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
        for _ in 0..<200 where anchors.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(anchors == [.topLeft])
        #expect(HUDAnchorStore.load(defaults) == .topLeft)
        #expect(stops == 0)
        #expect(hud.showsSummary)
        let placed = try #require(hud.panelFrame)
        #expect(placed.minX == screen.minX + HUDAnchor.defaultMargin)
        #expect(placed.maxY == screen.maxY - HUDAnchor.defaultMargin)
    }

    @Test func eachReplyAppearsOnTheFocusedWindowsDisplayAtTheSharedPosition() throws {
        let screens = FakeDisplays([1: CGRect(x: 0, y: 0, width: 800, height: 600), 2: CGRect(x: 900, y: 0, width: 800, height: 900)])
        let defaults = scratchDefaults()
        HUDAnchorStore.save(.bottomCenter, defaults)
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults, displays: screens.displays)
        defer { hud.hide() }

        screens.focused = 1
        hud.show(name: "keyscribe blue", summary: "Done.")
        let first = try #require(hud.panelFrame)
        #expect(screens.frames[1]!.contains(first))
        #expect(first.minY == screens.frames[1]!.minY + HUDAnchor.defaultMargin)

        screens.focused = 2
        hud.speaking()
        hud.toggleSummary()
        hud.finished()
        #expect(screens.frames[1]!.contains(try #require(hud.panelFrame)))
        hud.hide()

        hud.show(name: "Ask", summary: "Reply by Friday.", answer: true, preparing: true)
        let second = try #require(hud.panelFrame)
        #expect(screens.frames[2]!.contains(second))
        #expect(second.minY == screens.frames[2]!.minY + HUDAnchor.defaultMargin)
    }

    @Test func aReplyFollowsItsDisplayWhenItChangesAndNeverReturnsToOneThatWentAway() throws {
        let screens = FakeDisplays([1: CGRect(x: 0, y: 0, width: 800, height: 600), 2: CGRect(x: 900, y: 0, width: 800, height: 600)])
        let defaults = scratchDefaults()
        HUDAnchorStore.save(.bottomCenter, defaults)
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: defaults, displays: screens.displays)
        defer { hud.hide() }

        screens.focused = 2
        hud.show(name: "keyscribe blue", summary: "Done.")
        screens.frames[2] = CGRect(x: 900, y: 200, width: 1000, height: 700)
        hud.screensChanged()
        let moved = try #require(hud.panelFrame)
        #expect(screens.frames[2]!.contains(moved))
        #expect(moved.minY == screens.frames[2]!.minY + HUDAnchor.defaultMargin)
        hud.hide()

        screens.frames[2] = nil
        screens.focused = nil
        hud.show(name: "keyscribe blue", summary: "Done again.")
        #expect(screens.frames[1]!.contains(try #require(hud.panelFrame)))
    }

    @Test func theCrampedPreviewShortensWhicheverDisplayThePanelUses() throws {
        let screens = FakeDisplays([1: CGRect(x: 0, y: 0, width: 1200, height: 900), 2: CGRect(x: 1300, y: 0, width: 1200, height: 900)])
        screens.focused = 2
        let hud = SpeakingHUDController(
            escape: FakeChordRegistrar(), defaults: scratchDefaults(), displays: screens.displays.withVisibleHeight(120))
        defer { hud.hide() }
        hud.show(name: "keyscribe blue", summary: String(repeating: "A long sentence that keeps going. ", count: 12))
        hud.toggleSummary()
        let frame = try #require(hud.panelFrame)
        #expect(CGRect(x: 1300, y: 0, width: 1200, height: 120).contains(frame))
    }

    @Test func itShowsTheExactConversationNameAndNeverTakesKeyFocus() {
        let hud = SpeakingHUDController(escape: FakeChordRegistrar(), defaults: scratchDefaults(), displays: .unfocused)
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
        #expect(item.title == "Agent Reply Updates")
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
