import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct ScriptTrialModelTests {
    private typealias FakeSystem = VoiceCommandRunnerTests.FakeSystem

    private let channel = VoiceCommandScript(name: "Channel", run: ["/bin/channel", "--find", "{text}"])
    private let backup = VoiceCommandScript(name: "Backup", run: ["/bin/backup"])

    private func make() -> (ScriptTrialModel, FakeSystem) {
        let system = FakeSystem()
        return (ScriptTrialModel(system: system), system)
    }

    private func finished(_ report: ScriptReport = ScriptReport(), status: Int32 = 0) -> ScriptRun {
        .finished(status: status, lastError: nil, report: report)
    }

    private func options(_ count: Int) -> ScriptReport {
        ScriptReport(options: (1...count).map { .init(value: "C\($0)", label: "#channel-\($0)") })
    }

    @Test func theSampleWordsStandInForTheSpokenPart() async {
        let (model, system) = make()
        await model.run(channel, sample: "  general  ")
        #expect(system.scriptRuns.map(\.program) == ["/bin/channel"])
        #expect(system.scriptRuns.map(\.arguments) == [["--find", "general"]])
        #expect(system.scriptChoices == [nil])
        #expect(model.result?.outcome == .done(summary: "Channel", command: "/bin/channel --find general"))
    }

    @Test func eachRunHandsTheLauncherAFreshCapture() async {
        let (model, system) = make()
        await model.run(backup, sample: "")
        await model.run(backup, sample: "")
        #expect(system.scriptCaptures.count == 2)
        #expect(system.scriptCaptures.allSatisfy { $0 != nil })
        #expect(system.scriptCaptures[0] !== system.scriptCaptures[1])
    }

    @Test func whatTheCaptureHeldIsShownWithTheResult() async {
        let (model, system) = make()
        system.whileCapturing = { capture in
            capture.appendOutput(Data("hello\n".utf8))
            capture.appendError(Data("warning\n".utf8))
            capture.exited(0)
        }
        await model.run(backup, sample: "")
        #expect(model.result?.output.output.text == "hello\n")
        #expect(model.result?.output.errors.text == "warning\n")
        #expect(model.result?.output.status == 0)
    }

    @Test func aScriptThatNeedsWordsIsNotRunWithoutThem() async {
        let (model, system) = make()
        #expect(ScriptTrialModel.missingSample(channel, sample: "   ") == VoiceCommandRunner.needsTextMessage(script: "Channel"))
        #expect(ScriptTrialModel.missingSample(channel, sample: "general") == nil)
        #expect(ScriptTrialModel.missingSample(backup, sample: "") == nil)
        await model.run(channel, sample: " ")
        #expect(system.scriptRuns.isEmpty)
        #expect(model.result?.outcome == .failed(message: VoiceCommandRunner.needsTextMessage(script: "Channel")))
    }

    @Test func sampleWordsAreIgnoredForAScriptThatTakesNone() async {
        let (model, system) = make()
        await model.run(backup, sample: "leftover words")
        #expect(system.scriptRuns.map(\.arguments) == [[]])
        #expect(model.result?.outcome == .done(summary: "Backup", command: "/bin/backup"))
    }

    @Test func aRefusedProgramIsNotRun() async {
        let (model, system) = make()
        await model.run(VoiceCommandScript(name: "Shell", run: ["/bin/sh", "-c", "{text}"]), sample: "ls")
        #expect(system.scriptRuns.isEmpty)
        guard case .failed(let message, _, _, _) = model.result?.outcome else { Issue.record("expected a refusal"); return }
        #expect(message.hasPrefix("Shell was not run."))
    }

    @Test func choicesOfferedInTimeAreListedAndPickingOneRunsItAgainWithTheChoice() async {
        let (model, system) = make()
        system.scriptResult = finished(options(2))
        await model.run(channel, sample: "gen")
        #expect(model.choices.map(\.name) == ["#channel-1", "#channel-2"])
        system.scriptResult = finished(ScriptReport(message: .init(level: .done, text: "Opened #channel-2")))
        await model.choose(model.choices[1].identity)
        #expect(system.scriptRuns.map(\.arguments) == [["--find", "gen"], ["--find", "gen"]])
        #expect(system.scriptChoices == [nil, "C2"])
        #expect(model.result?.outcome == .done(summary: "Channel", command: "/bin/channel --find gen",
                                               report: .init(level: .done, text: "Opened #channel-2")))
        #expect(model.choices.isEmpty)
    }

    @Test func tooManyChoicesFailAsTheyDoWhenSpoken() async {
        let (model, system) = make()
        system.scriptResult = finished(options(6))
        await model.run(channel, sample: "gen")
        #expect(model.choices.isEmpty)
        #expect(model.result?.outcome == .failed(
            message: "Channel offered 6 choices, more than can be listed.", command: "/bin/channel --find gen"))
    }

    @Test func choicesOfferedAfterTheReportWindowFailAsTheyDoWhenSpoken() async {
        let (model, system) = make()
        system.scriptResult = .stillRunning
        await model.run(channel, sample: "gen")
        #expect(model.result?.outcome == .started(summary: "Channel", command: "/bin/channel --find gen"))
        #expect(model.result?.finishedLate == false)
        system.finishLate?(finished(options(2)))
        #expect(model.result?.outcome == .failed(message: "Channel took too long to offer a choice.", command: "/bin/channel --find gen"))
        #expect(model.result?.finishedLate == true)
        #expect(model.choices.isEmpty)
    }

    @Test func runOnceWontStartAgainWhileTheLastRunIsStillGoing() async {
        let (model, system) = make()
        system.scriptResult = .stillRunning
        await model.run(backup, sample: "")
        await model.run(backup, sample: "")
        #expect(system.scriptRuns.count == 1)
        system.finishLate?(finished())
        await model.run(backup, sample: "")
        #expect(system.scriptRuns.count == 2)
    }

    @Test func editingTheDraftClearsTheEarlierRunAndItsChoices() async {
        let (model, system) = make()
        system.scriptResult = finished(options(2))
        await model.run(channel, sample: "gen")
        let identity = model.choices[0].identity
        model.draftChanged(to: channel, sample: "gen")
        #expect(model.choices.count == 2)
        model.draftChanged(to: channel, sample: "other")
        #expect(model.choices.isEmpty)
        #expect(model.result == nil)
        await model.choose(identity)
        #expect(system.scriptRuns.count == 1)
    }

    @Test func editingTheProgramWithdrawsChoicesToo() async {
        let (model, system) = make()
        system.scriptResult = finished(options(2))
        await model.run(channel, sample: "gen")
        model.draftChanged(to: VoiceCommandScript(id: channel.id, name: "Channel", say: [], run: ["/bin/other", "{text}"]), sample: "gen")
        #expect(model.choices.isEmpty)
    }

    @Test func aChoiceRunsTheSnapshotThatOfferedIt() async {
        let (model, system) = make()
        system.scriptResult = finished(options(2))
        await model.run(channel, sample: "gen")
        model.draftChanged(to: channel, sample: "gen")
        await model.choose(model.choices[0].identity)
        #expect(system.scriptRuns.map(\.program) == ["/bin/channel", "/bin/channel"])
        #expect(system.scriptChoices == [nil, "C1"])
    }

    @Test func aLateFinishAfterTheDraftChangedIsDropped() async {
        let (model, system) = make()
        system.scriptResult = .stillRunning
        await model.run(channel, sample: "gen")
        model.draftChanged(to: channel, sample: "other")
        #expect(model.result == nil)
        system.finishLate?(finished(ScriptReport(message: .init(level: .done, text: "Late"))))
        #expect(model.result == nil)
    }

    @Test func aRunThatFinishesInTimeIsNoLongerRunning() async {
        let (model, system) = make()
        var seenRunning: Bool?
        system.whileRunningScript = { seenRunning = model.isRunning }
        await model.run(backup, sample: "")
        #expect(seenRunning == true)
        #expect(!model.isRunning)
    }

    @Test func aScriptStillRunningKeepsRunOnceBusyUntilItEnds() async {
        let (model, system) = make()
        system.scriptResult = .stillRunning
        await model.run(backup, sample: "")
        #expect(model.isRunning)
        system.finishLate?(finished())
        #expect(!model.isRunning)
    }

    @Test func clearingTheResultDoesNotFreeRunOnceWhileTheScriptStillRuns() async {
        let (model, system) = make()
        system.scriptResult = .stillRunning
        await model.run(channel, sample: "gen")
        model.draftChanged(to: channel, sample: "other")
        #expect(model.result == nil)
        #expect(model.isRunning)
        system.finishLate?(finished())
        #expect(!model.isRunning)
        #expect(model.result == nil)
    }

    @Test func anEditWhileTheRunIsStartingDiscardsItsResult() async {
        let (model, system) = make()
        system.scriptResult = finished(options(2))
        system.whileRunningScript = { model.draftChanged(to: channel, sample: "other") }
        await model.run(channel, sample: "gen")
        #expect(model.result == nil)
        #expect(model.choices.isEmpty)
        #expect(!model.isRunning)
    }

    @Test func anUnchangedDraftWhileTheRunIsStartingKeepsItsResult() async {
        let (model, system) = make()
        system.whileRunningScript = { model.draftChanged(to: channel, sample: " gen ") }
        await model.run(channel, sample: "gen")
        #expect(model.result?.outcome == .done(summary: "Channel", command: "/bin/channel --find gen"))
    }

    @Test func aFinishArrivingBeforeTheFirstResultIsShownIsKept() async {
        let (model, system) = make()
        system.scriptResult = .stillRunning
        system.whileRunningScript = {
            system.finishLate?(.finished(status: 0, lastError: nil,
                                         report: ScriptReport(message: .init(level: .done, text: "Early"))))
        }
        await model.run(backup, sample: "")
        #expect(model.result?.outcome == .done(summary: "Backup", command: "/bin/backup", report: .init(level: .done, text: "Early")))
        #expect(model.result?.finishedLate == true)
        #expect(!model.isRunning)
    }

    @Test func theExitStatusSaysWhyThereIsNone() async {
        let (model, system) = make()
        system.scriptResult = .stillRunning
        await model.run(backup, sample: "")
        #expect(model.result?.statusText == "Started, still running")
        system.finishLate?(finished(status: 4))
        system.scriptResult = finished(status: 4)
        system.whileCapturing = { $0.exited(4) }
        await model.run(backup, sample: "")
        #expect(model.result?.statusText == "4")
        system.whileCapturing = { _ in }
        system.scriptResult = .notRunnable
        await model.run(backup, sample: "")
        #expect(model.result?.statusText == "Not started")
        await model.run(channel, sample: "")
        #expect(model.result?.statusText == "Not started")
    }
}
