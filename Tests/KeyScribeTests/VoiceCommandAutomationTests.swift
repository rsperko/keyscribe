import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct VoiceCommandAutomationTests {
    private let denied = "execution error: Not authorized to send Apple events to Music. (-1743)"
    private let manager = VoiceCommandScript(name: "Manager", run: ["/bin/manager", "{text}"])

    private func error(_ text: String, status: Int32 = 1) -> ScriptError? {
        ScriptLauncher.error(in: Data(text.utf8), status: status)
    }

    @Test func aNotAuthorizedAppleEventIsRecognized() {
        #expect(error(denied + "\n") == ScriptError(line: denied, blocksAutomation: true))
        #expect(error("Error: Error: Not authorized to send Apple events to System Events. (-1743)")?.blocksAutomation == true)
    }

    @Test func aLongLineOrALaterLineKeepsTheRecognition() {
        let long = "execution error: Not authorized to send Apple events to " + String(repeating: "x", count: 400) + ". (-1743)"
        let truncated = error(long)
        #expect(truncated?.blocksAutomation == true)
        #expect(truncated?.line.count == ScriptLauncher.errorLineLimit + 1)
        #expect(error(denied + "\ncleaning up\n") == ScriptError(line: denied, blocksAutomation: true))
    }

    @Test(arguments: [
        "Permission denied",
        "no such file or directory",
        "moved (-1743) items to the archive",
        "error -1743 is not this one",
        "Not authorized to send Apple events to Music.",
    ])
    func otherFailuresAreNotCalledAutomation(_ text: String) {
        #expect(error(text)?.blocksAutomation == false)
    }

    @Test func aProcessThatSucceededIsNeverCalledBlocked() {
        #expect(error(denied, status: 0)?.blocksAutomation == false)
    }

    @Test func aBlockedScriptSaysHowToCheckAndKeepsItsOwnError() {
        let command = manager.commandLine(arguments: ["alpha"])
        let blocked = ScriptRun.finished(status: 1, lastError: ScriptError(line: denied, blocksAutomation: true))
        #expect(VoiceCommandRunner.outcome(of: blocked, script: manager, command: command) == .failed(
            message: "Manager couldn\u{2019}t control another app. Check Automation access for \(Branding.appName). Error: \(denied)",
            command: command, action: .openAutomationSettings))
        let generic = ScriptRun.finished(status: 1, lastError: "Permission denied")
        #expect(VoiceCommandRunner.outcome(of: generic, script: manager, command: command)
                == .failed(message: "Manager failed (exit 1): Permission denied", command: command))
    }

    @Test func aBlockedScriptReportedLateGetsTheSameRepair() async {
        let system = VoiceCommandRunnerTests.FakeSystem()
        let runner = VoiceCommandRunner(system: system)
        system.scriptResult = .stillRunning
        var late: [VoiceCommandOutcome] = []
        _ = await runner.run(transcript: "run manager alpha", places: [], scripts: [manager], origin: nil,
                             onLateResult: { late.append($0) })
        system.finishLate?(.finished(status: 1, lastError: ScriptError(line: denied, blocksAutomation: true)))
        guard case .failed(_, _, let action, _) = late.first else { Issue.record("expected a late failure, got \(late)"); return }
        #expect(action == .openAutomationSettings)
    }

    @Test func aBrowserThatRefusedControlOffersTheSameRepair() async {
        let runner = VoiceCommandRunner(system: VoiceCommandRunnerTests.FakeSystem())
        guard case .failed(_, _, let action, _) = await runner.run(.browserNotAllowed("com.google.Chrome"), origin: nil) else {
            Issue.record("expected a failure"); return
        }
        #expect(action == .openAutomationSettings)
    }

    @Test func theRepairOpensAutomationSettings() {
        #expect(HUDErrorAction.openAutomationSettings.buttonTitle == "Open Automation Settings")
        #expect(Permissions.SettingsPane.automation.urlString.hasSuffix("?Privacy_Automation"))
    }
}
