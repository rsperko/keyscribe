import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandWindowRunnerTests {
    private typealias FakeSystem = VoiceCommandRunnerTests.FakeSystem
    private typealias Window = VoiceCommandCatalog.Window

    private let code = VoiceCommandCatalog.App(name: "Visual Studio Code", bundleId: "com.microsoft.VSCode")
    private let ghostty = VoiceCommandCatalog.App(name: "Ghostty", bundleId: "com.mitchellh.ghostty")
    private let studio = VoiceCommandCatalog.App(name: "Android Studio", bundleId: "com.google.android.studio")

    private func window(_ title: String, id: String, pid: Int32 = 20) -> Window {
        Window(bundleId: code.bundleId, appName: code.name, pid: pid, id: id, title: title)
    }

    private var keyscribe: Window { window("plan.md \u{2014} keyscribe", id: "cg:1") }
    private var budget: Window { window("budget.md \u{2014} finance", id: "cg:2") }
    private let textEdit = VoiceCommandOrigin(bundleId: "com.apple.TextEdit", pid: 30, windowId: "cg:90")

    private func make() -> (VoiceCommandRunner, FakeSystem) {
        let system = FakeSystem()
        system.running = [code, ghostty]
        system.windowScan = .complete([keyscribe, budget])
        system.runningPids = [20: code.bundleId, 30: "com.apple.TextEdit"]
        return (VoiceCommandRunner(system: system), system)
    }

    private func switchTo(_ runner: VoiceCommandRunner, _ target: String, from origin: VoiceCommandOrigin?) async -> VoiceCommandOutcome {
        await runner.run(transcript: "switch to \(target)", places: [], origin: origin)
    }

    @Test func aWindowTitleBringsThatWindowForward() async {
        let (runner, system) = make()
        let outcome = await switchTo(runner, "keyscribe", from: textEdit)
        #expect(outcome == .done(
            summary: "plan.md \u{2014} keyscribe \u{00B7} Visual Studio Code",
            command: "Brings the window \u{201C}plan.md \u{2014} keyscribe\u{201D} in Visual Studio Code to the front."))
        #expect(system.focusedWindows == [keyscribe])
        #expect(system.opened.isEmpty)
        #expect(runner.backTarget == textEdit)
    }

    @Test func windowsAreReadOnceAndOnlyWhenNeeded() async {
        let (runner, system) = make()
        _ = await switchTo(runner, "ghostty", from: textEdit)
        #expect(system.windowReads == 0)
        _ = await switchTo(runner, "keyscribe", from: textEdit)
        #expect(system.windowReads == 1)
    }

    @Test func anUnfinishedScanNavigatesNowhere() async {
        let (runner, system) = make()
        system.installed = [studio]
        system.windowScan = .incomplete
        #expect(await switchTo(runner, "android", from: textEdit) == .failed(message: VoiceCommandRunner.windowsIncompleteMessage))
        system.windowScan = .needsAccessibility
        #expect(await switchTo(runner, "android", from: textEdit) == .failed(
            message: VoiceCommandRunner.windowsNeedAccessibilityMessage, action: .openAccessibilitySettings))
        #expect(system.opened.isEmpty && system.focusedWindows.isEmpty)
        #expect(runner.backTarget == nil)
    }

    @Test func aCompletedMissSaysWindowsWereChecked() async {
        let (runner, _) = make()
        #expect(await switchTo(runner, "banana", from: textEdit) == .failed(message: VoiceCommandRunner.noMatchMessage("banana")))
        #expect(VoiceCommandRunner.noMatchMessage("banana") == "No matching app, place, or window found for \u{201C}banana\u{201D}.")
    }

    @Test(arguments: [
        (WindowFocusResult.gone, VoiceCommandRunner.windowGoneMessage),
        (.noResponse, VoiceCommandRunner.windowNotForwardMessage("Visual Studio Code")),
        (.failed, VoiceCommandRunner.windowNotForwardMessage("Visual Studio Code")),
        (.elsewhere, VoiceCommandRunner.windowElsewhereMessage),
    ])
    func aWindowThatCannotComeForwardRaisesNoSubstitute(result: WindowFocusResult, message: String) async {
        let (runner, system) = make()
        system.windowFocusResults = [result]
        guard case .failed(let shown, _, _, _) = await switchTo(runner, "keyscribe", from: textEdit) else {
            Issue.record("expected a failure"); return
        }
        #expect(shown == message)
        #expect(system.opened.isEmpty && system.activatedPids.isEmpty)
        #expect(system.focusedWindows == [keyscribe])
        #expect(runner.backTarget == nil)
    }

    @Test func anAlreadyFrontmostWindowSucceedsAndKeepsTheReturnSlot() async {
        let (runner, system) = make()
        _ = await switchTo(runner, "keyscribe", from: textEdit)
        system.windowFocusResults = [.alreadyFrontmost]
        let here = VoiceCommandOrigin(bundleId: code.bundleId, pid: 20, windowId: "cg:1")
        guard case .done = await switchTo(runner, "keyscribe", from: here) else { Issue.record("expected success"); return }
        #expect(runner.backTarget == textEdit)
    }

    @Test func cancellationWhileFocusingReportsNothingAndKeepsTheSlot() async {
        let (runner, system) = make()
        var wanted = true
        system.whileFocusingWindow = { wanted = false }
        let outcome = await runner.run(transcript: "switch to keyscribe", places: [], origin: textEdit, stillWanted: { wanted })
        #expect(outcome == .abandoned)
        #expect(runner.backTarget == nil)
    }

    @Test func goBackReturnsToTheExactWindowAndToggles() async {
        let (runner, system) = make()
        let first = VoiceCommandOrigin(bundleId: code.bundleId, pid: 20, windowId: "cg:2")
        _ = await switchTo(runner, "keyscribe", from: first)
        let there = VoiceCommandOrigin(bundleId: code.bundleId, pid: 20, windowId: "cg:1")
        guard case .done = await runner.run(transcript: "go back", places: [], origin: there) else {
            Issue.record("expected go back to succeed"); return
        }
        #expect(system.focusedWindows.last?.id == "cg:2")
        #expect(system.focusedWindows.last?.pid == 20)
        #expect(runner.backTarget == there)
        _ = await runner.run(transcript: "go back", places: [], origin: first)
        #expect(system.focusedWindows.last?.id == "cg:1")
        #expect(runner.backTarget == first)
    }

    @Test func goBackAfterAnAppCommandIsWindowAware() async {
        let (runner, system) = make()
        _ = await switchTo(runner, "ghostty", from: textEdit)
        _ = await runner.run(transcript: "go back", places: [], origin: .init(bundleId: ghostty.bundleId))
        #expect(system.focusedWindows.map(\.id) == ["cg:90"])
        #expect(system.focusedWindows.map(\.pid) == [30])
    }

    @Test func aClosedRememberedWindowFallsBackToItsOriginalProcess() async {
        let (runner, system) = make()
        _ = await switchTo(runner, "keyscribe", from: textEdit)
        system.windowFocusResults = [.gone]
        guard case .done = await runner.run(transcript: "go back", places: [], origin: nil) else {
            Issue.record("expected the app fallback"); return
        }
        #expect(system.activatedPids == [30])
        #expect(system.opened.isEmpty)
    }

    @Test(arguments: [WindowFocusResult.noResponse, .failed])
    func aRememberedWindowThatDoesNotAnswerKeepsTheSlot(result: WindowFocusResult) async {
        let (runner, system) = make()
        _ = await switchTo(runner, "keyscribe", from: textEdit)
        system.windowFocusResults = [result]
        guard case .failed = await runner.run(transcript: "go back", places: [], origin: nil) else {
            Issue.record("expected a failure"); return
        }
        #expect(system.activatedPids.isEmpty && system.opened.isEmpty)
        #expect(runner.backTarget == textEdit)
    }

    @Test func aRelaunchedAppIsNotTheOneToGoBackTo() async {
        let (runner, system) = make()
        _ = await switchTo(runner, "keyscribe", from: textEdit)
        system.windowFocusResults = [.gone]
        system.runningPids = [20: code.bundleId, 31: "com.apple.TextEdit"]
        #expect(await runner.run(transcript: "go back", places: [], origin: nil) == .failed(message: "Nothing to go back to."))
        #expect(system.activatedPids.isEmpty && system.opened.isEmpty)
    }

    @Test func aChosenWindowIsFocusedByIdentityWithoutAnotherScan() async throws {
        let (runner, system) = make()
        let twin = window("plan.md \u{2014} keyscribe", id: "cg:3")
        system.windowScan = .complete([keyscribe, twin])
        guard case .needsChoice(let pending) = await switchTo(runner, "keyscribe", from: textEdit) else {
            Issue.record("expected a choice"); return
        }
        #expect(system.windowReads == 1)
        let id = try #require(runner.claimChoice())
        let reply = await runner.answer("two", choice: id, places: [], scripts: [], origin: nil)
        guard case .selected(let selection) = reply, case .done = selection.outcome else {
            Issue.record("expected the second window to be focused"); return
        }
        #expect(pending.rows.map(\.identity) == ["window:com.microsoft.VSCode:20:cg:1", "window:com.microsoft.VSCode:20:cg:3"])
        #expect(system.focusedWindows == [twin])
        #expect(system.windowReads == 1)
        #expect(runner.backTarget == textEdit)
    }

    @Test func anOriginKeepsOnlyAStableWindowId() {
        #expect(VoiceCommandOrigin(bundleId: "a", pid: 1, windowId: "t:Doc|p:1,2").windowId == nil)
        #expect(VoiceCommandOrigin(bundleId: "a", pid: 1, windowId: "cg:5").windowId == "cg:5")
    }
}
