import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct VoiceCommandSidebarRunnerTests {
    private let slackId = "com.tinyspeck.slackmacgap"
    private var slackApp: VoiceCommandCatalog.App { VoiceCommandCatalog.App(name: "Slack", bundleId: slackId) }
    private var work: VoiceCommandPlace { VoiceCommandPlace(name: "Work", target: .app(bundleId: slackId)) }
    private var general: VoiceCommandCatalog.SidebarItem {
        VoiceCommandCatalog.SidebarItem(bundleId: slackId, pid: 42, name: "general", section: "Channels", path: [1, 0, 0])
    }

    final class Clock { var now: Double = 0 }
    private let clock = Clock()

    private func make(findsInApps: Bool = true, isPreview: Bool = false) -> (VoiceCommandRunner, VoiceCommandRunnerTests.FakeSystem) {
        let system = VoiceCommandRunnerTests.FakeSystem()
        let clock = clock
        system.running = [slackApp]
        system.sidebar = .listing(SidebarListing(items: [general], isComplete: true))
        let runner = VoiceCommandRunner(
            system: system, findsInApps: { findsInApps }, isPreview: isPreview, pause: { clock.now += $0 }, now: { clock.now })
        return (runner, system)
    }

    @Test func nothingIsReadOrOpenedWhileFindingInAppsIsOff() async {
        let (runner, system) = make(findsInApps: false)
        #expect(await runner.run(transcript: "work general", places: [work], origin: nil)
                == .failed(message: VoiceCommandRunner.takesNoTextMessage("Work")))
        _ = await runner.run(transcript: "open slack general", places: [], origin: nil)
        #expect(system.sidebarReads.isEmpty)
        #expect(await runner.run(.action(.sidebarItem(general)), origin: nil)
                == .failed(message: VoiceCommandRunner.sidebarTurnedOffMessage))
        #expect(system.openedSidebarItems.isEmpty)
    }

    @Test func anAppNameAndAnItemOpenTheItemWithNothingSaved() async {
        let (runner, system) = make()
        let outcome = await runner.run(transcript: "open slack general", places: [], origin: nil)
        guard case .done = outcome else { Issue.record("expected done, got \(outcome)"); return }
        #expect(system.sidebarReads == [slackId])
        #expect(system.openedSidebarItems == [general])
        #expect(system.tabReads.isEmpty)
    }

    @Test func aSavedNicknameAndAnItemOpenTheItem() async {
        let (runner, system) = make()
        _ = await runner.run(transcript: "work general", places: [work], origin: nil)
        #expect(system.openedSidebarItems == [general])
    }

    @Test func aBrowserNameAndWordsFindATabInThatBrowser() async {
        let (runner, system) = make()
        let chromeId = "com.google.Chrome"
        system.running = [VoiceCommandCatalog.App(name: "Chrome", bundleId: chromeId)]
        system.tabBrowserIds = [chromeId]
        let tab = VoiceCommandCatalog.Tab(browserBundleId: chromeId, window: 1, tab: 3, url: "https://slashdot.org", title: "Slashdot")
        system.tabs = [tab]
        _ = await runner.run(transcript: "open chrome slashdot", places: [], origin: nil)
        #expect(system.tabReads == [chromeId])
        #expect(system.focused == [tab])
        #expect(system.sidebarReads.isEmpty)
    }

    @Test func otherCommandsNeverReadASidebar() async {
        let (runner, system) = make()
        _ = await runner.run(transcript: "switch to slack", places: [work], origin: nil)
        _ = await runner.run(transcript: "work", places: [work], origin: nil)
        #expect(system.sidebarReads.isEmpty)
        #expect(system.opened == [slackId, slackId])
    }

    @Test func anAppThatIsNotRunningIsOpenedAndThenSearched() async {
        let (runner, system) = make()
        system.sidebar = .unreadable(.notRunning)
        system.sidebarOnceOpened = .listing(SidebarListing(items: [general], isComplete: true))
        _ = await runner.run(transcript: "work general", places: [work], origin: nil)
        #expect(system.opened.first == slackId)
        #expect(system.openedSidebarItems == [general])
    }

    @Test func anEmptySidebarAfterOpeningIsAnAnswerNotAWait() async {
        let (runner, system) = make()
        system.sidebar = .unreadable(.notRunning)
        system.sidebarOnceOpened = .listing(SidebarListing(items: [], isComplete: true))
        #expect(await runner.run(transcript: "work general", places: [work], origin: nil)
                == .failed(message: VoiceCommandRunner.noSidebarMatchMessage("general", app: "Slack")))
        #expect(system.sidebarReads.count == 1 + VoiceCommandRunner.emptySidebarSettleReads)
    }

    @Test func openingAnAppSaysWhatItIsDoing() async {
        let (runner, system) = make()
        system.sidebar = .unreadable(.notRunning)
        system.sidebarOnceOpened = .listing(SidebarListing(items: [general], isComplete: true))
        var progress: [VoiceCommandProgress] = []
        runner.onProgress = { progress.append($0) }
        _ = await runner.run(transcript: "work general", places: [work], origin: nil)
        #expect(progress == [.opening("Slack"), .looking("Slack")])
        #expect(VoiceCommandProgress.opening("Slack").text == "Opening Slack\u{2026}")
    }

    @Test func aRunningAppReportsNoProgress() async {
        let (runner, _) = make()
        var progress: [VoiceCommandProgress] = []
        runner.onProgress = { progress.append($0) }
        _ = await runner.run(transcript: "work general", places: [work], origin: nil)
        #expect(progress.isEmpty)
    }

    @Test func aSidebarThatNeverAppearsAfterOpeningSaysToTryAgain() async {
        let (runner, system) = make()
        system.sidebar = .unreadable(.notRunning)
        system.sidebarOnceOpened = .unreadable(.noSidebar)
        #expect(await runner.run(transcript: "work general", places: [work], origin: nil)
                == .failed(message: "Opened Slack, but its sidebar isn\u{2019}t ready yet. Try again."))
        #expect(clock.now <= VoiceCommandRunner.launchWaitSeconds + 1)
        #expect(system.openedSidebarItems.isEmpty)
    }

    @Test func slowReadsStillStopAtTheStartupDeadline() async {
        let (runner, system) = make()
        let clock = clock
        system.sidebar = .unreadable(.notRunning)
        system.sidebarOnceOpened = .unreadable(.noSidebar)
        system.whileReadingSidebar = { clock.now += 2 }
        #expect(await runner.run(transcript: "work general", places: [work], origin: nil)
                == .failed(message: "Opened Slack, but its sidebar isn\u{2019}t ready yet. Try again."))
        #expect(system.sidebarReads.count == 4)
    }

    @Test func aCommandCancelledBeforeTheAppOpensNeverOpensIt() async {
        let (runner, system) = make()
        system.sidebar = .unreadable(.notRunning)
        system.sidebarOnceOpened = .listing(SidebarListing(items: [general], isComplete: true))
        #expect(await runner.run(transcript: "work general", places: [work], origin: nil, stillWanted: { false }) == .abandoned)
        #expect(system.opened.isEmpty)
        #expect(system.openedSidebarItems.isEmpty)
    }

    @Test func aCommandCancelledWhileTheAppStartsStopsWaiting() async {
        let (runner, system) = make()
        system.sidebar = .unreadable(.notRunning)
        system.sidebarOnceOpened = .unreadable(.noSidebar)
        #expect(await runner.run(
            transcript: "work general", places: [work], origin: nil, stillWanted: { system.opened.isEmpty }) == .abandoned)
        #expect(system.sidebarReads == [slackId])
    }

    @Test func aBrowserThatIsNotOpenIsOpenedAndThenSearched() async {
        let (runner, system) = make()
        let chromeId = "com.google.Chrome"
        system.running = []
        system.installed = [VoiceCommandCatalog.App(name: "Chrome", bundleId: chromeId)]
        system.tabBrowserIds = [chromeId]
        let tab = VoiceCommandCatalog.Tab(browserBundleId: chromeId, window: 1, tab: 1, url: "https://slashdot.org", title: "Slashdot")
        system.tabsOnceOpened = [tab]
        _ = await runner.run(transcript: "open chrome slashdot", places: [], origin: nil)
        #expect(system.opened.first == chromeId)
        #expect(system.focused == [tab])
    }

    private func closedChrome(_ system: VoiceCommandRunnerTests.FakeSystem) -> String {
        let chromeId = "com.google.Chrome"
        system.running = []
        system.installed = [VoiceCommandCatalog.App(name: "Chrome", bundleId: chromeId)]
        system.tabBrowserIds = [chromeId]
        return chromeId
    }

    @Test func thePreviewNeverOpensAClosedBrowser() async {
        let (runner, system) = make(isPreview: true)
        let chromeId = closedChrome(system)
        #expect(await runner.resolve("open chrome github", places: []) == .noTabMatch("github", browser: chromeId))
        #expect(system.opened.isEmpty)
    }

    @Test func aBrowserThatRefusesControlWhileStartingStopsAtOnce() async {
        let (runner, system) = make()
        let chromeId = closedChrome(system)
        system.refused = [chromeId]
        #expect(await runner.run(transcript: "open chrome github", places: [], origin: nil)
                == .failed(message: VoiceCommandRunner.notAllowedMessage(browser: "Chrome")))
        #expect(system.tabReads == [chromeId])
    }

    @Test func aBrowserWhoseTabsCannotBeReadWhileStartingStopsAtOnce() async {
        let (runner, system) = make()
        let chromeId = closedChrome(system)
        system.tabsUnreadable = true
        #expect(await runner.run(transcript: "open chrome github", places: [], origin: nil)
                == .failed(message: "Chrome did not list its open tabs, so no tab was opened."))
        #expect(system.tabReads == [chromeId])
    }

    @Test func thePreviewNeverReadsASidebar() async {
        let (runner, system) = make(isPreview: true)
        #expect(await runner.resolve("open slack general", places: []) == .needsSidebar(slackId))
        #expect(system.sidebarReads.isEmpty)
        #expect(system.opened.isEmpty)
    }

    @Test(arguments: [
        (SidebarProblem.noSidebar, "No sidebar was found in Slack\u{2019}s front window, so nothing was opened."),
        (.noResponse, "Slack did not respond, so nothing was opened."),
    ])
    func anUnreadableSidebarSaysWhy(problem: SidebarProblem, message: String) async {
        let (runner, system) = make()
        system.sidebar = .unreadable(problem)
        #expect(await runner.run(transcript: "work general", places: [work], origin: nil) == .failed(message: message))
        #expect(system.openedSidebarItems.isEmpty)
    }

    @Test func missingAccessibilityOffersItsSettings() async {
        let (runner, system) = make()
        system.sidebar = .unreadable(.needsAccessibility)
        #expect(await runner.run(transcript: "work general", places: [work], origin: nil)
                == .failed(message: VoiceCommandRunner.sidebarNeedsAccessibilityMessage("Slack"), action: .openAccessibilitySettings))
    }

    @Test func noMatchingEntryOpensNothing() async {
        let (runner, system) = make()
        #expect(await runner.run(transcript: "work payroll", places: [work], origin: nil)
                == .failed(message: "Nothing shown in Slack\u{2019}s sidebar matches \u{201C}payroll\u{201D}. Only items the sidebar shows can be found; expand a section or scroll the sidebar, then try again."))
        #expect(system.openedSidebarItems.isEmpty)
    }

    @Test func anOpenThatCannotBeConfirmedSaysSo() async {
        let (runner, system) = make()
        system.sidebarOpenResult = .unconfirmed
        #expect(await runner.run(transcript: "work general", places: [work], origin: nil)
                == .done(summary: "general \u{00B7} Slack",
                         command: "Pressed \u{201C}general\u{201D} in Slack\u{2019}s sidebar, but could not confirm that it opened.",
                         report: ScriptReport.Message(
                            level: .info, text: "Could not confirm that \u{201C}general\u{201D} opened in Slack.")))
    }

    @Test func anEntryThatMovedIsReported() async {
        let (runner, system) = make()
        system.sidebarOpenResult = .gone
        guard case .failed(let message, _, _, _) = await runner.run(transcript: "work general", places: [work], origin: nil) else {
            Issue.record("expected a failure"); return
        }
        #expect(message == "general is no longer in Slack\u{2019}s sidebar, so nothing was opened.")
    }

    @Test func aMatchFromAnIncompleteReadOpensWithoutAsking() async {
        let (runner, system) = make()
        system.sidebar = .listing(SidebarListing(items: [general], isComplete: false))
        guard case .done = await runner.run(transcript: "work general", places: [work], origin: nil) else {
            Issue.record("expected the item to open"); return
        }
        #expect(system.openedSidebarItems == [general])
    }

    @Test func aSidebarReadWithoutAWindowIdentityIsRefused() {
        let outline = SidebarNode(role: "AXOutline", children: [
            SidebarNode(role: "AXRow", subrole: "AXOutlineRow", title: "general"),
        ])
        #expect(SidebarAccess.result(of: outline, bundleId: slackId, pid: 42, window: nil) == .unreadable(.windowUnknown))
        guard case .listing(let listing) = SidebarAccess.result(of: outline, bundleId: slackId, pid: 42, window: 9) else {
            Issue.record("expected a listing"); return
        }
        #expect(listing.items.map(\.window) == [9])
    }

    @Test func anUnidentifiedWindowSaysWhy() async {
        let (runner, system) = make()
        system.sidebar = .unreadable(.windowUnknown)
        #expect(await runner.run(transcript: "work general", places: [work], origin: nil)
                == .failed(message: "Slack\u{2019}s front window could not be identified, so nothing was opened."))
    }

    @Test func stepsStopAsSoonAsTheCommandIsNoLongerWanted() {
        var ran: [String] = []
        var wanted = true
        let steps = [
            SidebarAccess.Step(isRequired: false) { ran.append("raise"); wanted = false; return true },
            SidebarAccess.Step(isRequired: true) { ran.append("press"); return true },
        ]
        #expect(SidebarAccess.perform(steps, isCurrent: { wanted }) == .noResponse)
        #expect(ran == ["raise"])
    }

    @Test func aFailedOptionalStepDoesNotStopTheOpen() {
        var ran: [String] = []
        let steps = [
            SidebarAccess.Step(isRequired: false) { ran.append("raise"); return false },
            SidebarAccess.Step(isRequired: true) { ran.append("press"); return true },
        ]
        #expect(SidebarAccess.perform(steps, isCurrent: { true }) == .opened)
        #expect(ran == ["raise", "press"])
        #expect(SidebarAccess.perform([SidebarAccess.Step(isRequired: true) { false }], isCurrent: { true }) == .noResponse)
    }

    @Test func nothingRunsOnceTheCommandWasAbandoned() {
        var ran = false
        #expect(SidebarAccess.perform([SidebarAccess.Step(isRequired: true) { ran = true; return true }], isCurrent: { false })
                == .noResponse)
        #expect(!ran)
    }

    @Test func duplicateEntriesOpenTheFirstWithoutAsking() async {
        let (runner, system) = make()
        let person = VoiceCommandCatalog.SidebarItem(bundleId: slackId, pid: 42, name: "design", section: "Direct Messages", path: [2, 0, 0])
        let channel = VoiceCommandCatalog.SidebarItem(bundleId: slackId, pid: 42, name: "design", section: "Channels", path: [1, 0, 1])
        system.sidebar = .listing(SidebarListing(items: [channel, person], isComplete: true))
        _ = await runner.run(transcript: "work design", places: [work], origin: nil)
        #expect(system.openedSidebarItems == [channel])
    }
}
