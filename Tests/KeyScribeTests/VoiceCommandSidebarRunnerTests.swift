import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct VoiceCommandSidebarRunnerTests {
    private let slackId = "com.tinyspeck.slackmacgap"
    private var slack: VoiceCommandPlace { VoiceCommandPlace(name: "Slack", target: .sidebar(bundleId: slackId)) }
    private var general: VoiceCommandCatalog.SidebarItem {
        VoiceCommandCatalog.SidebarItem(bundleId: slackId, pid: 42, name: "general", section: "Channels", path: [1, 0, 0])
    }

    private func make() -> (VoiceCommandRunner, VoiceCommandRunnerTests.FakeSystem) {
        let system = VoiceCommandRunnerTests.FakeSystem()
        system.running = [VoiceCommandCatalog.App(name: "Slack", bundleId: slackId)]
        system.sidebar = .listing(SidebarListing(items: [general], isComplete: true))
        return (VoiceCommandRunner(system: system, sidebarEnabled: { true }), system)
    }

    @Test func nothingIsReadOrOpenedWhileSidebarSearchIsOff() async {
        let system = VoiceCommandRunnerTests.FakeSystem()
        system.running = [VoiceCommandCatalog.App(name: "Slack", bundleId: slackId)]
        system.sidebar = .listing(SidebarListing(items: [general], isComplete: true))
        let runner = VoiceCommandRunner(system: system)
        #expect(await runner.run(transcript: "slack general", places: [slack], origin: nil)
                == .failed(message: VoiceCommandRunner.sidebarTurnedOffMessage))
        #expect(system.sidebarReads.isEmpty)
        #expect(await runner.run(.action(.sidebarItem(general)), origin: nil)
                == .failed(message: VoiceCommandRunner.sidebarTurnedOffMessage))
        #expect(system.openedSidebarItems.isEmpty)
    }

    @Test func theAppAloneStillOpensWhileSidebarSearchIsOff() async {
        let system = VoiceCommandRunnerTests.FakeSystem()
        system.running = [VoiceCommandCatalog.App(name: "Slack", bundleId: slackId)]
        _ = await VoiceCommandRunner(system: system).run(transcript: "slack", places: [slack], origin: nil)
        #expect(system.opened == [slackId])
    }

    @Test func aSidebarEntryIsReadAndOpened() async {
        let (runner, system) = make()
        let outcome = await runner.run(transcript: "slack general", places: [slack], origin: nil)
        guard case .done = outcome else { Issue.record("expected done, got \(outcome)"); return }
        #expect(system.sidebarReads == [slackId])
        #expect(system.openedSidebarItems == [general])
        #expect(system.tabReads.isEmpty)
    }

    @Test func otherCommandsNeverReadASidebar() async {
        let (runner, system) = make()
        _ = await runner.run(transcript: "switch to slack", places: [slack], origin: nil)
        _ = await runner.run(transcript: "slack", places: [slack], origin: nil)
        #expect(system.sidebarReads.isEmpty)
        #expect(system.opened == [slackId, slackId])
    }

    @Test(arguments: [
        (SidebarProblem.notRunning, "Slack is not open, so its sidebar was not checked. Open it, then try again."),
        (.noSidebar, "No sidebar was found in Slack\u{2019}s front window, so nothing was opened."),
        (.noResponse, "Slack did not respond, so nothing was opened."),
    ])
    func anUnreadableSidebarSaysWhy(problem: SidebarProblem, message: String) async {
        let (runner, system) = make()
        system.sidebar = .unreadable(problem)
        #expect(await runner.run(transcript: "slack general", places: [slack], origin: nil) == .failed(message: message))
        #expect(system.openedSidebarItems.isEmpty)
    }

    @Test func missingAccessibilityOffersItsSettings() async {
        let (runner, system) = make()
        system.sidebar = .unreadable(.needsAccessibility)
        #expect(await runner.run(transcript: "slack general", places: [slack], origin: nil)
                == .failed(message: VoiceCommandRunner.sidebarNeedsAccessibilityMessage("Slack"), action: .openAccessibilitySettings))
    }

    @Test func noMatchingEntryOpensNothing() async {
        let (runner, system) = make()
        #expect(await runner.run(transcript: "slack payroll", places: [slack], origin: nil)
                == .failed(message: "Nothing in Slack\u{2019}s sidebar matches \u{201C}payroll\u{201D}."))
        #expect(system.openedSidebarItems.isEmpty)
    }

    @Test func anOpenThatCannotBeConfirmedSaysSo() async {
        let (runner, system) = make()
        system.sidebarOpenResult = .unconfirmed
        #expect(await runner.run(transcript: "slack general", places: [slack], origin: nil)
                == .done(summary: "general \u{00B7} Slack",
                         command: "Pressed \u{201C}general\u{201D} in Slack\u{2019}s sidebar, but could not confirm that it opened.",
                         report: ScriptReport.Message(
                            level: .info, text: "Could not confirm that \u{201C}general\u{201D} opened in Slack.")))
    }

    @Test func aCheckDescribesTheSidebarOrWhyItCannotBeRead() async {
        let (_, system) = make()
        #expect(await VoiceCommandRunner.checkSidebar(of: slackId, system: system)
                == "Found 1 entry in Slack\u{2019}s front window, such as general.")
        system.sidebar = .unreadable(.notRunning)
        #expect(await VoiceCommandRunner.checkSidebar(of: slackId, system: system)
                == VoiceCommandRunner.sidebarNotRunningMessage("Slack"))
        system.sidebar = .unreadable(.noSidebar, switchedOnAccessibility: true)
        #expect(await VoiceCommandRunner.checkSidebar(of: slackId, system: system)
                == VoiceCommandRunner.noSidebarMessage("Slack") + " " + SidebarListing.switchedNote(appName: "Slack"))
        #expect(system.sidebarReads == [slackId, slackId, slackId])
    }

    @Test func anEntryThatMovedIsReported() async {
        let (runner, system) = make()
        system.sidebarOpenResult = .gone
        guard case .failed(let message, _, _, _) = await runner.run(transcript: "slack general", places: [slack], origin: nil) else {
            Issue.record("expected a failure"); return
        }
        #expect(message == "general is no longer in Slack\u{2019}s sidebar, so nothing was opened.")
    }

    @Test func anIncompleteReadAsksBeforeOpeningAndTheAnswerOpensIt() async {
        let (runner, system) = make()
        system.sidebar = .listing(SidebarListing(items: [general], isComplete: false))
        guard case .needsChoice(let pending) = await runner.run(transcript: "slack general", places: [slack], origin: nil) else {
            Issue.record("expected a choice"); return
        }
        #expect(system.openedSidebarItems.isEmpty)
        _ = await runner.runChoice(pending, candidate: pending.rows[0].identity, places: [slack], scripts: [])
        #expect(system.openedSidebarItems == [general])
        #expect(system.sidebarReads == [slackId])
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
        #expect(await runner.run(transcript: "slack general", places: [slack], origin: nil)
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

    @Test func duplicateEntriesAskAndTheAnswerOpensTheChosenOne() async {
        let (runner, system) = make()
        let person = VoiceCommandCatalog.SidebarItem(bundleId: slackId, pid: 42, name: "design", section: "Direct Messages", path: [2, 0, 0])
        let channel = VoiceCommandCatalog.SidebarItem(bundleId: slackId, pid: 42, name: "design", section: "Channels", path: [1, 0, 1])
        system.sidebar = .listing(SidebarListing(items: [channel, person], isComplete: true))
        guard case .needsChoice(let pending) = await runner.run(transcript: "slack design", places: [slack], origin: nil) else {
            Issue.record("expected a choice"); return
        }
        #expect(pending.rows.map(\.detail) == ["Slack \u{00B7} Channels", "Slack \u{00B7} Direct Messages"])
        _ = await runner.runChoice(pending, candidate: pending.rows[1].identity, places: [slack], scripts: [])
        #expect(system.openedSidebarItems == [person])
    }
}
