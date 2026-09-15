import Foundation
import Testing
@testable import KeyScribeApp

@MainActor
private final class Probe {
    var events: [String] = []
    var trusted = false
    var outcome: TCCResetOutcome = .reset
    var pending: CheckedContinuation<TCCResetOutcome, Never>?
    var holdsReset = false

    func makeRecovery(bundleID: String? = "com.example.dictation") -> AccessibilityRecovery {
        AccessibilityRecovery(
            isTrusted: { self.trusted },
            bundleID: bundleID,
            resetService: { service, bundleID in
                self.events.append("reset:\(service):\(bundleID)")
                guard self.holdsReset else { return self.outcome }
                return await withCheckedContinuation { self.pending = $0 }
            },
            requestAccess: { self.events.append("request") })
    }
}

@MainActor
struct AccessibilityRecoveryTests {
    @Test func trustedAtClickTimeNeitherResetsNorRequests() async {
        let probe = Probe()
        probe.trusted = true
        let recovery = probe.makeRecovery()

        await recovery.request()

        #expect(probe.events.isEmpty)
        #expect(!recovery.didAttemptReset)
    }

    @Test func untrustedResetsOnlyItsOwnAccessibilityEntryBeforeRequesting() async {
        let probe = Probe()
        let recovery = probe.makeRecovery()

        await recovery.request()

        #expect(probe.events == ["reset:Accessibility:com.example.dictation", "request"])
        #expect(recovery.didAttemptReset)
        #expect(!recovery.resetFailed)
    }

    @Test func missingBundleIDRequestsWithoutResetting() async {
        let probe = Probe()
        let recovery = probe.makeRecovery(bundleID: nil)

        await recovery.request()

        #expect(probe.events == ["request"])
        #expect(!recovery.didAttemptReset)
    }

    @Test func aLaterClickInTheSameProcessNeverResetsAgain() async {
        let probe = Probe()
        let recovery = probe.makeRecovery()

        await recovery.request()
        await recovery.request()

        #expect(probe.events == ["reset:Accessibility:com.example.dictation", "request", "request"])
    }

    @Test func overlappingClicksRunASingleReset() async {
        let probe = Probe()
        probe.holdsReset = true
        let recovery = probe.makeRecovery()

        let first = Task { await recovery.request() }
        while probe.pending == nil { await Task.yield() }
        #expect(recovery.isResetting)
        await recovery.request()
        probe.pending?.resume(returning: .reset)
        await first.value

        #expect(probe.events == ["reset:Accessibility:com.example.dictation", "request"])
        #expect(!recovery.isResetting)
    }

    @Test(arguments: [TCCResetOutcome.failed(exitCode: 1), .timedOut, .launchFailed])
    func anUnsuccessfulResetIsReportedAndStillRequests(outcome: TCCResetOutcome) async {
        let probe = Probe()
        probe.outcome = outcome
        let recovery = probe.makeRecovery()

        await recovery.request()

        #expect(recovery.resetFailed)
        #expect(probe.events.last == "request")
    }

    @Test func boundedRunnerReportsACleanExitAsReset() async {
        let outcome = await ResetTool.runBounded(URL(fileURLWithPath: "/usr/bin/true"), [], timeoutSeconds: 5)
        #expect(outcome == .reset)
    }

    @Test func boundedRunnerReportsANonZeroExit() async {
        let outcome = await ResetTool.runBounded(URL(fileURLWithPath: "/usr/bin/false"), [], timeoutSeconds: 5)
        #expect(outcome == .failed(exitCode: 1))
    }

    @Test func boundedRunnerTerminatesAProcessThatOutlivesItsBudget() async {
        let started = Date()
        let outcome = await ResetTool.runBounded(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeoutSeconds: 0.2)
        #expect(outcome == .timedOut)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func boundedRunnerReportsAnExecutableThatCannotLaunch() async {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let outcome = await ResetTool.runBounded(missing, [], timeoutSeconds: 5)
        #expect(outcome == .launchFailed)
    }
}
