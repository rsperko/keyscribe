import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandScriptReportTests {
    private typealias FakeSystem = VoiceCommandRunnerTests.FakeSystem

    private let channel = VoiceCommandScript(name: "Channel", run: ["/bin/channel", "{text}"])
    private let origin = VoiceCommandOrigin(bundleId: "com.apple.TextEdit")

    private func make() -> (VoiceCommandRunner, FakeSystem) {
        let system = FakeSystem()
        return (VoiceCommandRunner(system: system), system)
    }

    private func finished(_ report: ScriptReport, status: Int32 = 0, error: ScriptError? = nil) -> ScriptRun {
        .finished(status: status, lastError: error, report: report)
    }

    private func options(_ count: Int) -> ScriptReport {
        ScriptReport(options: (1...count).map { .init(value: "C\($0)", label: "#channel-\($0)") })
    }

    private func run(_ runner: VoiceCommandRunner, onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void = { _ in })
        async -> VoiceCommandOutcome {
        await runner.run(transcript: "run channel gen", places: [], scripts: [channel], origin: origin,
                         onLateResult: onLateResult)
    }

    @Test func aDoneMessageIsReportedWithTheCommand() async {
        let (runner, system) = make()
        system.scriptResult = finished(ScriptReport(message: .init(level: .done, text: "Opened #general")))
        #expect(await run(runner) == .done(summary: "Channel", command: "/bin/channel gen",
                                           report: .init(level: .done, text: "Opened #general")))
    }

    @Test func anInfoMessageIsReportedWithTheCommand() async {
        let (runner, system) = make()
        system.scriptResult = finished(ScriptReport(message: .init(level: .info, text: "Nothing waiting")))
        #expect(await run(runner) == .done(summary: "Channel", command: "/bin/channel gen",
                                           report: .init(level: .info, text: "Nothing waiting")))
    }

    @Test func aFailureShowsTheReportedMessageInsteadOfTheErrorLine() async {
        let (runner, system) = make()
        system.scriptResult = finished(ScriptReport(message: .init(level: .info, text: "Not signed in")), status: 2, error: "Traceback noise")
        #expect(await run(runner) == .failed(message: "Channel failed (exit 2): Not signed in", command: "/bin/channel gen"))
    }

    @Test func offeredOptionsAskWhichOneUnderTheScript() async throws {
        let (runner, system) = make()
        system.scriptResult = finished(options(2))
        guard case .needsChoice(let pending) = await run(runner) else { Issue.record("expected a choice"); return }
        #expect(pending.choice.title == "Which one?")
        #expect(pending.rows.map(\.name) == ["#channel-1", "#channel-2"])
        #expect(pending.rows.map(\.detail) == ["Channel", "Channel"])
        #expect(pending.request == "run channel gen")
        #expect(runner.pendingChoice == pending)
        #expect(system.scriptRuns.count == 1)
    }

    @Test func answeringRunsTheScriptAgainWithItsArgumentsAndTheChosenValue() async throws {
        let (runner, system) = make()
        system.scriptResult = finished(options(2))
        _ = await run(runner)
        system.scriptResult = finished(ScriptReport(message: .init(level: .done, text: "Opened #channel-2")))
        let id = try #require(runner.claimChoice())
        let reply = await runner.answer("two", choice: id, places: [], scripts: [channel], origin: origin)
        guard case .selected(let selection) = reply else { Issue.record("expected a selection, got \(reply)"); return }
        #expect(selection.name == "#channel-2")
        #expect(selection.outcome == .done(summary: "Channel", command: "/bin/channel gen",
                                           report: .init(level: .done, text: "Opened #channel-2")))
        #expect(system.scriptRuns.map(\.arguments) == [["gen"], ["gen"]])
        #expect(system.scriptChoices == [nil, "C2"])
    }

    @Test func aClickedOptionRunsTheScriptAgainWithThatValue() async throws {
        let (runner, system) = make()
        system.scriptResult = finished(options(2))
        guard case .needsChoice(let pending) = await run(runner) else { Issue.record("expected a choice"); return }
        system.scriptResult = finished(ScriptReport())
        let taken = try #require(runner.takeChoice(pending.id))
        let selection = await runner.runChoice(taken, candidate: pending.rows[0].identity, places: [], scripts: [channel])
        #expect(selection?.name == "#channel-1")
        #expect(system.scriptChoices == [nil, "C1"])
    }

    @Test func cancellingRunsNothing() async throws {
        let (runner, system) = make()
        system.scriptResult = finished(options(2))
        _ = await run(runner)
        let id = try #require(runner.claimChoice())
        #expect(await runner.answer("cancel", choice: id, places: [], scripts: [channel], origin: origin)
            == .cancelled(request: "run channel gen"))
        #expect(system.scriptRuns.count == 1)
    }

    @Test func aRerunCanAskAgain() async throws {
        let (runner, system) = make()
        system.scriptResult = finished(options(2))
        _ = await run(runner)
        let id = try #require(runner.claimChoice())
        let reply = await runner.answer("one", choice: id, places: [], scripts: [channel], origin: origin)
        guard case .selected(let selection) = reply, case .needsChoice(let next) = selection.outcome else {
            Issue.record("expected another choice, got \(reply)"); return
        }
        #expect(next.id != id)
        #expect(runner.pendingChoice == next)
    }

    @Test func tooManyOptionsAskTheScriptToNarrowThemDown() async {
        let (runner, system) = make()
        system.scriptResult = finished(options(VoiceCommandChoice.displayLimit + 1))
        #expect(await run(runner) == .failed(
            message: "Channel offered 6 choices, more than can be listed.", command: "/bin/channel gen"))
        #expect(runner.pendingChoice == nil)
    }

    @Test func optionsFromAFailedRunAreIgnored() async {
        let (runner, system) = make()
        system.scriptResult = finished(options(2), status: 1, error: "boom")
        #expect(await run(runner) == .failed(message: "Channel failed (exit 1): boom", command: "/bin/channel gen"))
        #expect(runner.pendingChoice == nil)
    }

    @Test func optionsAreNotOfferedOnceTheCommandIsNoLongerWanted() async {
        let (runner, system) = make()
        system.scriptResult = finished(options(2))
        var wanted = true
        system.whileRunningScript = { wanted = false }
        let outcome = await runner.run(transcript: "run channel gen", places: [], scripts: [channel], origin: origin,
                                       stillWanted: { wanted })
        #expect(outcome == .abandoned)
        #expect(runner.pendingChoice == nil)
    }

    @Test func aClickedRerunDoesNotOfferOptionsOnceItIsNoLongerWanted() async throws {
        let (runner, system) = make()
        system.scriptResult = finished(options(2))
        guard case .needsChoice(let pending) = await run(runner) else { Issue.record("expected a choice"); return }
        let taken = try #require(runner.takeChoice(pending.id))
        var wanted = true
        system.whileRunningScript = { wanted = false }
        let selection = await runner.runChoice(
            taken, candidate: pending.rows[0].identity, places: [], scripts: [channel], stillWanted: { wanted })
        #expect(selection?.outcome == .abandoned)
        #expect(runner.pendingChoice == nil)
    }

    private let journal = VoiceCommandScript(
        name: "Journal", shortcut: VoiceCommandShortcut(name: "Journal Entry", identifier: "6E98", input: "{text}"))

    @Test func aShortcutsMarkerShapedOutputIsIgnored() async {
        let (runner, system) = make()
        system.scriptResult = finished(ScriptReport(message: .init(level: .done, text: "Saved"),
                                                    options: [.init(value: "a", label: "A")]))
        let outcome = await runner.run(transcript: "run journal buy milk", places: [], scripts: [journal], origin: origin)
        guard case .done(_, _, nil) = outcome else { Issue.record("expected a plain completion, got \(outcome)"); return }
        #expect(runner.pendingChoice == nil)
    }

    @Test func aFailedShortcutKeepsItsErrorLineOverMarkerShapedOutput() async {
        let (runner, system) = make()
        system.scriptResult = finished(ScriptReport(message: .init(level: .info, text: "Saved")), status: 1, error: "No input")
        #expect(await runner.run(transcript: "run journal buy milk", places: [], scripts: [journal], origin: origin)
            == .failed(message: "Journal failed: No input", command: journal.commandLine(arguments: ["buy milk"])))
    }

    @Test func aLateShortcutsMarkerShapedOutputIsIgnored() async {
        let (runner, system) = make()
        system.scriptResult = .stillRunning
        var late: [VoiceCommandOutcome] = []
        _ = await runner.run(transcript: "run journal buy milk", places: [], scripts: [journal], origin: origin,
                             onLateResult: { late.append($0) })
        system.finishLate?(finished(ScriptReport(message: .init(level: .done, text: "Saved"),
                                                 options: [.init(value: "a", label: "A")])))
        #expect(late == [.done(summary: "Journal", command: journal.commandLine(arguments: ["buy milk"]))])
    }

    @Test func aLateMessageIsReported() async {
        let (runner, system) = make()
        system.scriptResult = .stillRunning
        var late: [VoiceCommandOutcome] = []
        _ = await run(runner) { late.append($0) }
        system.finishLate?(finished(ScriptReport(message: .init(level: .done, text: "Opened #general"))))
        #expect(late == [.done(summary: "Channel", command: "/bin/channel gen",
                               report: .init(level: .done, text: "Opened #general"))])
    }

    @Test func lateOptionsAreNotOffered() async {
        let (runner, system) = make()
        system.scriptResult = .stillRunning
        var late: [VoiceCommandOutcome] = []
        _ = await run(runner) { late.append($0) }
        system.finishLate?(finished(options(2)))
        #expect(late == [.failed(message: "Channel took too long to offer a choice.", command: "/bin/channel gen")])
        #expect(runner.pendingChoice == nil)
    }
}
