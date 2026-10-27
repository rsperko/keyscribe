import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandChoiceRunnerTests {
    private typealias FakeSystem = VoiceCommandRunnerTests.FakeSystem

    private final class Clock {
        var now: Double = 100
    }

    private let safari = VoiceCommandCatalog.App(name: "Safari", bundleId: "com.apple.Safari")
    private let chrome = VoiceCommandCatalog.App(name: "Google Chrome", bundleId: "com.google.Chrome")
    private let ghostty = VoiceCommandCatalog.App(name: "Ghostty", bundleId: "com.mitchellh.ghostty")
    private let textEdit = VoiceCommandOrigin(bundleId: "com.apple.TextEdit")
    private let personal = VoiceCommandPlace(
        name: "Personal Mail", say: ["mail"], target: .url("https://mail.example.net/"), browser: "com.apple.Safari")
    private let work = VoiceCommandPlace(
        name: "Work Mail", say: ["mail"], target: .url("https://inbox.example.org/"), browser: "com.google.Chrome")

    private func make() -> (VoiceCommandRunner, FakeSystem, Clock) {
        let system = FakeSystem()
        system.running = [safari, chrome, ghostty]
        let clock = Clock()
        return (VoiceCommandRunner(system: system, now: { clock.now }), system, clock)
    }

    private func ask(_ runner: VoiceCommandRunner, places: [VoiceCommandPlace]? = nil) async -> VoiceCommandPendingChoice? {
        let outcome = await runner.run(transcript: "open mail", places: places ?? [personal, work], origin: textEdit)
        guard case .needsChoice(let pending) = outcome else { return nil }
        return pending
    }

    private func answer(
        _ runner: VoiceCommandRunner, _ text: String, places: [VoiceCommandPlace]? = nil,
        scripts: [VoiceCommandScript] = [], origin: VoiceCommandOrigin? = nil
    ) async -> VoiceCommandAnswer? {
        guard let id = runner.claimChoice() else { return nil }
        return await runner.answer(text, choice: id, places: places ?? [personal, work], scripts: scripts,
                                   origin: origin ?? VoiceCommandOrigin(bundleId: "com.example.elsewhere"))
    }

    @Test func anAmbiguousCommandAsksInsteadOfRunning() async throws {
        let (runner, system, _) = make()
        let pending = try #require(await ask(runner))
        #expect(pending.rows.map(\.name) == ["Personal Mail", "Work Mail"])
        #expect(pending.rows.map(\.detail) == ["Safari \u{00B7} mail.example.net", "Google Chrome \u{00B7} inbox.example.org"])
        #expect(pending.request == "open mail")
        #expect(runner.pendingChoice == pending)
        #expect(system.opened.isEmpty && system.openedURLs.isEmpty && system.focused.isEmpty)
    }

    @Test func aSpokenNumberRunsThatRowFromTheOriginalApp() async throws {
        let (runner, system, _) = make()
        _ = try #require(await ask(runner))
        let reply = await answer(runner, "the second one")
        guard case .selected(let selection) = reply else { Issue.record("expected a selection, got \(String(describing: reply))"); return }
        #expect(selection.name == "Work Mail")
        #expect(selection.request == "open mail")
        #expect(system.openedURLs.map(\.0) == ["https://inbox.example.org/"])
        #expect(runner.backTarget == textEdit)
        #expect(runner.pendingChoice == nil)
    }

    @Test func theChosenPlaceReadsTabsAgainWhenItIsChosen() async throws {
        let (runner, system, _) = make()
        _ = try #require(await ask(runner))
        let tab = VoiceCommandCatalog.Tab(
            browserBundleId: chrome.bundleId, window: 1, tab: 2, url: "https://inbox.example.org/today", title: "Inbox")
        system.tabs = [tab]
        _ = await answer(runner, "two")
        #expect(system.focused == [tab])
    }

    @Test func aDestinationRemovedWhileWaitingIsReportedRatherThanReplaced() async throws {
        let (runner, system, _) = make()
        _ = try #require(await ask(runner))
        let reply = await answer(runner, "two", places: [personal])
        #expect(reply == .selected(VoiceCommandSelection(
            name: "Work Mail", request: "open mail",
            outcome: .failed(message: VoiceCommandRunner.unavailableMessage("Work Mail")))))
        #expect(system.openedURLs.isEmpty)
    }

    @Test func anAppThatQuitWhileChoosingLaunchesOnlyWhenOpening() async throws {
        let notesA = VoiceCommandCatalog.App(name: "Notes Alpha", bundleId: "com.example.a")
        let notesB = VoiceCommandCatalog.App(name: "Notes Beta", bundleId: "com.example.b")
        for (verb, launches) in [("open", true), ("switch to", false)] {
            let (runner, system, _) = make()
            system.running = [notesA, notesB]
            system.installed = [notesA, notesB]
            let outcome = await runner.run(transcript: "\(verb) notes", places: [], origin: textEdit)
            guard case .needsChoice = outcome else { Issue.record("expected a choice"); return }
            system.running = []
            let reply = await answer(runner, "2", places: [])
            #expect(system.opened == (launches ? [notesB.bundleId] : []))
            #expect(system.activatedPids.isEmpty)
            if !launches {
                #expect(reply == .selected(VoiceCommandSelection(name: "Notes Beta", request: "switch to notes", outcome: .failed(
                    message: "Notes Beta isn\u{2019}t running. Say \u{201C}open Notes Beta\u{201D} to start it."))))
            }
        }
    }

    @Test func aSwitchChoiceKeepsItsReachForAClickedRow() async throws {
        let (runner, system, _) = make()
        let notesA = VoiceCommandCatalog.App(name: "Notes Alpha", bundleId: "com.example.a")
        let notesB = VoiceCommandCatalog.App(name: "Notes Beta", bundleId: "com.example.b")
        system.running = [notesA, notesB]
        guard case .needsChoice(let pending) = await runner.run(transcript: "switch to notes", places: [], origin: textEdit) else {
            Issue.record("expected a choice"); return
        }
        #expect(pending.choice.reach == .running)
        system.running = [notesA]
        _ = await runner.runChoice(pending, candidate: pending.rows[1].identity, places: [], scripts: [])
        #expect(system.opened.isEmpty)
        #expect(system.activatedPids.isEmpty)
    }

    @Test func aFreshCommandReplacesTheChoice() async throws {
        let (runner, system, _) = make()
        _ = try #require(await ask(runner))
        let reply = await answer(runner, "open Ghostty")
        guard case .command(.done) = reply else { Issue.record("expected the new command to run"); return }
        #expect(system.opened == [ghostty.bundleId])
        #expect(runner.pendingChoice == nil)
    }

    @Test func aSavedPhraseSaidOnItsOwnIsANewCommandNotAFailedAnswer() async throws {
        let (runner, system, _) = make()
        let terminal = VoiceCommandPlace(name: "Terminal", target: .app(bundleId: ghostty.bundleId))
        _ = try #require(await ask(runner, places: [personal, work, terminal]))
        guard case .command(let outcome) = await answer(runner, "terminal", places: [personal, work, terminal]) else {
            Issue.record("expected a new command"); return
        }
        #expect(outcome == .done(summary: "Terminal", command: "Brings Ghostty to the front, opening it if needed."))
        #expect(system.opened == [ghostty.bundleId])
    }

    @Test func anUnrecognizedOrOutOfRangeReplyKeepsTheList() async throws {
        let (runner, system, _) = make()
        let pending = try #require(await ask(runner))
        let message = "Choose 1\u{2013}2, say \u{201C}cancel\u{201D}, or give a new command."
        #expect(await answer(runner, "seven") == .retry(message: message, reason: .invalidSelection))
        #expect(runner.resumeChoice(pending.id))
        #expect(await answer(runner, "the work one I think") == .retry(message: message, reason: .unrecognizedAnswer))
        #expect(runner.resumeChoice(pending.id))
        #expect(runner.pendingChoice?.id == pending.id)
        #expect(system.opened.isEmpty && system.openedURLs.isEmpty)
    }

    @Test func spokenCancelDismissesWithoutRunningAnything() async throws {
        let (runner, system, _) = make()
        _ = try #require(await ask(runner))
        #expect(await answer(runner, "never mind") == .cancelled(request: "open mail"))
        #expect(runner.pendingChoice == nil)
        #expect(system.openedURLs.isEmpty)
    }

    @Test func theChoiceExpiresWhenIdleButNotWhileBeingAnswered() async throws {
        let (runner, _, clock) = make()
        let pending = try #require(await ask(runner))
        clock.now += 29
        #expect(!runner.expireChoice(pending.id))
        let id = try #require(runner.claimChoice())
        clock.now += 20
        #expect(!runner.expireChoice(id))
        #expect(runner.resumeChoice(id))
        clock.now += 29
        #expect(runner.choiceSecondsLeft(id) == 1)
        clock.now += 1
        #expect(runner.expireChoice(id))
        #expect(runner.pendingChoice == nil)
    }

    @Test func anExpiredChoiceCannotBeClaimed() async throws {
        let (runner, _, clock) = make()
        _ = try #require(await ask(runner))
        clock.now += 31
        #expect(runner.claimChoice() == nil)
        #expect(runner.pendingChoice == nil)
    }

    @Test func aNumberAfterDismissalIsJustAnUtterance() async throws {
        let (runner, system, _) = make()
        let pending = try #require(await ask(runner))
        let id = try #require(runner.claimChoice())
        runner.dismissChoice(pending.id)
        let reply = await runner.answer("two", choice: id, places: [personal, work], scripts: [], origin: textEdit)
        guard case .command(.failed) = reply else { Issue.record("expected an ordinary failed command"); return }
        #expect(system.openedURLs.isEmpty)
    }

    @Test func aClickAndAVoiceAnswerRunExactlyOneDestination() async throws {
        let (runner, system, _) = make()
        let pending = try #require(await ask(runner))
        let id = try #require(runner.claimChoice())
        let taken = try #require(runner.takeChoice(id))
        let reply = await runner.answer("two", choice: id, places: [personal, work], scripts: [], origin: textEdit)
        let clicked = await runner.runChoice(taken, candidate: pending.rows[0].identity, places: [personal, work], scripts: [])
        #expect(clicked?.name == "Personal Mail")
        guard case .command(.failed) = reply else { Issue.record("expected the voice answer to find no choice"); return }
        #expect(system.openedURLs.map(\.0) == ["https://mail.example.net/"])
    }

    @Test func anActionChoiceKeepsItsInputAndNeverPassesTheAnswer() async throws {
        let (runner, system, _) = make()
        let deploy = VoiceCommandScript(name: "Deploy", say: ["ship"], run: ["/bin/deploy", "{text}"])
        let note = VoiceCommandScript(name: "Notify", say: ["ship"], run: ["/bin/notify", "{text}"])
        let outcome = await runner.run(transcript: "run ship staging", places: [], scripts: [deploy, note], origin: textEdit)
        guard case .needsChoice(let pending) = outcome else { Issue.record("expected a choice"); return }
        #expect(pending.choice.family == .action)
        #expect(pending.rows.map(\.detail) == ["Script \u{00B7} deploy", "Script \u{00B7} notify"])
        _ = await answer(runner, "two", places: [], scripts: [deploy, note])
        #expect(system.scriptRuns.map(\.arguments) == [["staging"]])
        #expect(system.scriptRuns.map(\.program) == ["/bin/notify"])
    }

    @Test func moreThanFiveMatchesAskForMoreOfTheName() async {
        let (runner, system, _) = make()
        system.running = (1...6).map { VoiceCommandCatalog.App(name: "Note \($0)", bundleId: "com.example.note\($0)") }
        let outcome = await runner.run(transcript: "switch to note", places: [], origin: textEdit)
        #expect(outcome == .failed(message: "6 matches for \u{201C}note\u{201D}. Say more of the name."))
        #expect(runner.pendingChoice == nil)
    }

    @Test func aNewCommandAlwaysStartsWithoutAnOldChoice() async throws {
        let (runner, _, _) = make()
        let first = try #require(await ask(runner))
        let second = try #require(await ask(runner))
        #expect(first.id != second.id)
        #expect(runner.takeChoice(first.id) == nil)
        #expect(runner.pendingChoice?.id == second.id)
    }
}
