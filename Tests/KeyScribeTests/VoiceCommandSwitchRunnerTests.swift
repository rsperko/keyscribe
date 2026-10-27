import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandSwitchRunnerTests {
    private typealias FakeSystem = VoiceCommandRunnerTests.FakeSystem

    private let chrome = VoiceCommandCatalog.App(name: "Google Chrome", bundleId: "com.google.Chrome")
    private let slack = VoiceCommandCatalog.App(name: "Slack", bundleId: "com.tinyspeck.slackmacgap")
    private let textEdit = VoiceCommandCatalog.App(name: "TextEdit", bundleId: "com.apple.TextEdit")
    private let gmail = VoiceCommandPlace(name: "Gmail", target: .url("https://mail.google.com/"))

    private func make(findsInApps: Bool = false) -> (VoiceCommandRunner, FakeSystem) {
        let system = FakeSystem()
        system.running = [chrome, textEdit]
        system.installed = [chrome, slack, textEdit]
        return (VoiceCommandRunner(system: system, findsInApps: { findsInApps }, pause: { _ in }), system)
    }

    private func inbox(pid: Int32? = nil) -> VoiceCommandCatalog.Tab {
        VoiceCommandCatalog.Tab(
            browserBundleId: chrome.bundleId, window: 1, tab: 1, url: "https://mail.google.com/", title: "Inbox", pid: pid)
    }

    private func expectNothingStarted(_ system: FakeSystem) {
        #expect(system.opened.isEmpty)
        #expect(system.openedURLs.isEmpty)
    }

    @Test func switchingToAClosedAppStartsNothingAndSaysHowToOpenIt() async {
        let (runner, system) = make()
        #expect(await runner.run(transcript: "switch to slack", places: [], origin: nil)
                == .failed(message: "Slack isn\u{2019}t running. Say \u{201C}open Slack\u{201D} to start it."))
        expectNothingStarted(system)
        #expect(system.activatedPids.isEmpty)
    }

    @Test func anAppThatQuitAfterItWasFoundIsNotRestarted() async {
        let (runner, system) = make()
        let switched = await runner.run(.action(.app(slack)), origin: nil, reach: .running)
        #expect(switched == .failed(
            message: "Slack isn\u{2019}t running. Say \u{201C}open Slack\u{201D} to start it.", command: "Brings Slack to the front."))
        expectNothingStarted(system)
        #expect(await runner.run(.action(.app(slack)), origin: nil, reach: .opening)
                == .done(summary: "Slack", command: "Brings Slack to the front, opening it if needed."))
        #expect(system.opened == [slack.bundleId])
    }

    @Test func aSavedAppThatQuitAfterItWasFoundIsNotRestarted() async {
        let (runner, system) = make()
        let work = VoiceCommandPlace(name: "Work", target: .app(bundleId: slack.bundleId))
        #expect(await runner.run(.action(.place(work, .app(bundleId: slack.bundleId))), origin: nil, reach: .running)
                == .failed(message: "Slack isn\u{2019}t running. Say \u{201C}open Work\u{201D} to start it.",
                           command: "Brings Slack to the front."))
        expectNothingStarted(system)
    }

    @Test func switchingActivatesTheRunningProcessRatherThanOpeningTheApp() async {
        let (runner, system) = make()
        system.runningPids = [55: textEdit.bundleId]
        #expect(await runner.run(transcript: "switch to textedit", places: [], origin: nil)
                == .done(summary: "TextEdit", command: "Brings TextEdit to the front."))
        #expect(system.activatedPids == [55])
        expectNothingStarted(system)
    }

    @Test(arguments: [false, true])
    func aBrowserThatQuitsOnceItsTabIsFocusedIsNotRestarted(saved: Bool) async {
        let (runner, system) = make()
        system.tabs = [inbox()]
        system.whileFocusing = { system.running.removeAll { $0 == chrome } }
        let outcome = saved
            ? await runner.run(transcript: "open gmail", places: [gmail], origin: nil)
            : await runner.run(.action(.tab(inbox())), origin: nil, reach: .opening)
        guard case .failed(let message, _, _, _) = outcome else { Issue.record("expected a failure, got \(outcome)"); return }
        #expect(message == VoiceCommandRunner.tabGoneMessage)
        expectNothingStarted(system)
        #expect(system.activatedPids.isEmpty)
    }

    @Test(arguments: [false, true])
    func aTabRaisesTheBrowserProcessItWasReadFrom(saved: Bool) async {
        let (runner, system) = make()
        system.runningPids = [77: chrome.bundleId]
        system.tabs = [inbox(pid: 77)]
        if saved {
            _ = await runner.run(transcript: "switch to gmail", places: [gmail], origin: nil)
        } else {
            _ = await runner.run(.action(.tab(inbox(pid: 77))), origin: nil, reach: .running)
        }
        #expect(system.activatedPids == [77])
        expectNothingStarted(system)
    }

    @Test func aTabFromABrowserThatWasReplacedIsGoneRatherThanRaisedInTheNewOne() async {
        let (runner, system) = make()
        #expect(await runner.run(.action(.tab(inbox(pid: 77))), origin: nil, reach: .running)
                == .failed(message: VoiceCommandRunner.tabGoneMessage, command: "Focuses the open tab \u{201C}Inbox\u{201D} in Google Chrome."))
        #expect(system.activatedPids.isEmpty)
        expectNothingStarted(system)
    }

    @Test func goBackNeverStartsTheAppItReturnsTo() async {
        let (runner, system) = make()
        _ = await runner.run(transcript: "open slack", places: [], origin: .init(bundleId: textEdit.bundleId))
        system.running.removeAll { $0 == textEdit }
        #expect(await runner.run(transcript: "go back", places: [], origin: .init(bundleId: slack.bundleId))
                == .failed(message: "Nothing to go back to."))
        #expect(system.opened == [slack.bundleId])
    }

    @Test func goBackWithoutAProcessRaisesTheRunningOneInstead() async {
        let (runner, system) = make()
        system.runningPids = [55: textEdit.bundleId]
        _ = await runner.run(transcript: "open slack", places: [], origin: .init(bundleId: textEdit.bundleId))
        #expect(await runner.run(transcript: "go back", places: [], origin: .init(bundleId: slack.bundleId))
                == .done(summary: "TextEdit", command: "Returns to TextEdit."))
        #expect(system.activatedPids == [55])
        #expect(system.opened == [slack.bundleId])
    }

    @Test func switchingIntoAnAppThatQuitWhileReadingItsSidebarDoesNotStartIt() async {
        let (runner, system) = make(findsInApps: true)
        system.running = [slack]
        system.sidebar = .unreadable(.notRunning)
        var progress: [VoiceCommandProgress] = []
        runner.onProgress = { progress.append($0) }
        #expect(await runner.run(transcript: "switch to slack general", places: [], origin: nil)
                == .failed(message: VoiceCommandRunner.sidebarNotRunningMessage("Slack")))
        expectNothingStarted(system)
        #expect(system.sidebarReads == [slack.bundleId])
        #expect(progress.isEmpty)
    }

    @Test func switchingIntoAClosedAppNeitherStartsNorReadsIt() async {
        let (runner, system) = make(findsInApps: true)
        system.running = []
        system.tabBrowserIds = [chrome.bundleId]
        #expect(await runner.run(transcript: "switch to slack general", places: [], origin: nil)
                == .failed(message: "Slack isn\u{2019}t running. Say \u{201C}open Slack general\u{201D} to start it and find general."))
        #expect(await runner.run(transcript: "switch to google chrome github", places: [], origin: nil)
                == .failed(message: "Google Chrome isn\u{2019}t running. Say \u{201C}open Google Chrome github\u{201D} to start it and find github."))
        expectNothingStarted(system)
        #expect(system.sidebarReads.isEmpty)
        #expect(system.tabReads.isEmpty)
    }

    @Test func openingIntoAClosedAppStartsItAndSaysSo() async {
        let (runner, system) = make(findsInApps: true)
        system.running = []
        system.sidebar = .unreadable(.notRunning)
        system.sidebarOnceOpened = .listing(SidebarListing(items: [], isComplete: true))
        var progress: [VoiceCommandProgress] = []
        runner.onProgress = { progress.append($0) }
        _ = await runner.run(transcript: "open slack general", places: [], origin: nil)
        #expect(system.opened == [slack.bundleId])
        #expect(progress == [.opening("Slack"), .looking("Slack")])
    }

    @Test func aBrowserThatWouldNotListItsTabsIsNamedRatherThanCalledEmpty() async {
        let (runner, system) = make()
        system.refused = [chrome.bundleId]
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: nil)
                == .failed(message: VoiceCommandRunner.notAllowedMessage(browser: "Google Chrome"), action: .openAutomationSettings))
        system.refused = []
        system.unavailable = [chrome.bundleId]
        #expect(await runner.run(transcript: "switch to gmail", places: [gmail], origin: nil)
                == .failed(message: "Google Chrome did not list its open tabs, so no tab was opened."))
        expectNothingStarted(system)
    }

    @Test func switchingToAnAppLinkOpensNothing() async {
        let (runner, system) = make()
        let channel = VoiceCommandPlace(name: "Web Hooks", target: .url("slack://channel?team=T1&id=C1"))
        #expect(await runner.run(transcript: "switch to web hooks", places: [channel], origin: nil)
                == .failed(message: "\u{201C}Switch to\u{201D} only uses what\u{2019}s already open. Say \u{201C}open Web Hooks\u{201D} to open the saved link."))
        expectNothingStarted(system)
    }

    @Test func aSavedNameKeepsItsConfiguredOpeningWithoutAVerb() async {
        let (runner, system) = make()
        let work = VoiceCommandPlace(name: "Work", target: .app(bundleId: slack.bundleId))
        #expect(await runner.run(transcript: "work", places: [work], origin: nil)
                == .done(summary: "Work", command: "Brings Slack to the front, opening it if needed."))
        #expect(system.opened == [slack.bundleId])
    }
}
