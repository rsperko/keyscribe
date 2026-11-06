import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct InsertOutputTests {
    @MainActor private final class Rig {
        var snapshots: [TargetSnapshot] = []
        var inserted: [String] = []
        var submitted: [Mode.Submit] = []
        var actuates = true
        var wanted = true
        var acting = true
        var loseDuringInsert = false
        var accessibility = true

        func output() -> InsertOutput {
            InsertOutput(
                snapshotAsync: { [unowned self] in self.snapshots.isEmpty ? TargetSnapshot(bundleId: "app") : self.snapshots.removeFirst() },
                accessibilityGranted: { [unowned self] in self.accessibility },
                insert: { [unowned self] _, _, _, text, _ in
                    self.inserted.append(text)
                    if self.loseDuringInsert { self.wanted = false }
                    return self.actuates
                },
                submitKey: { [unowned self] in self.submitted.append($0) })
        }

        func lease() -> TakeLease {
            TakeLease(
                stillWanted: { [unowned self] in self.wanted }, beginActing: { [unowned self] in self.acting },
                abortsActuation: { false })
        }
    }

    private func request(
        _ text: String, heard: String = "words", submit: Mode.Submit = .none, submitOverride: Mode.Submit? = nil,
        stoppedAtLimit: String? = nil, trailing: String = ""
    ) -> InsertOutput.Request {
        .init(
            text: text, heard: heard, mode: nil, captured: TargetSnapshot(bundleId: "app"), trailing: trailing,
            submit: submit, submitOverride: submitOverride, stoppedAtLimit: stoppedAtLimit, paste: ClipboardPaste())
    }

    private func run(_ rig: Rig, _ request: InsertOutput.Request) async -> (InsertOutput.Result, String?) {
        var ready: String?
        let (result, _) = await rig.output().perform(request, lease: rig.lease()) { ready = $0 }
        return (result, ready)
    }

    @Test func aVerifiedInsertCarriesItsTrailingTextThenSubmits() async {
        let rig = Rig()
        let (result, ready) = await run(rig, request("Hello", submit: .return, trailing: " "))
        #expect(result == .done(.inserted))
        #expect(ready == "Hello")
        #expect(rig.inserted == ["Hello "])
        #expect(rig.submitted == [.return])
    }

    @Test func aTakeNoLongerWantedActsOnNothing() async {
        let rig = Rig()
        rig.wanted = false
        #expect(await run(rig, request("Hello")).0 == .abandoned)
        #expect(rig.inserted.isEmpty)
    }

    @Test func anotherTerminalThatWonTheRaceLeavesNothingToDo() async {
        let rig = Rig()
        rig.acting = false
        #expect(await run(rig, request("Hello")).0 == .preempted)
        #expect(rig.inserted.isEmpty)
    }

    @Test func losingTheTakeDuringActuationPressesNoReturn() async {
        let rig = Rig()
        rig.loseDuringInsert = true
        #expect(await run(rig, request("Hello", submit: .return)).0 == .abandoned)
        #expect(rig.submitted.isEmpty)
    }

    @Test func anInsertThatDidNotLandFailsAndPressesNoReturn() async {
        let rig = Rig()
        rig.actuates = false
        #expect(await run(rig, request("Hello", submit: .return)).0 == .done(.failed))
        #expect(rig.submitted.isEmpty)
    }

    @Test func focusMovingBeforeTheReturnSkipsOnlyTheReturn() async {
        let rig = Rig()
        rig.snapshots = [TargetSnapshot(bundleId: "app"), TargetSnapshot(bundleId: "other")]
        #expect(await run(rig, request("Hello", submit: .return)).0 == .done(.inserted))
        #expect(rig.inserted == ["Hello"])
        #expect(rig.submitted.isEmpty)
    }

    @Test func aReturnOnlyCommandPressesReturnInTheSameField() async {
        let rig = Rig()
        #expect(await run(rig, request("", submitOverride: .return)).0 == .done(.inserted))
        #expect(rig.submitted == [.return])
        #expect(rig.inserted.isEmpty)
    }

    @Test func aReturnOnlyCommandWithoutAccessibilitySaysWhy() async {
        let rig = Rig()
        rig.accessibility = false
        guard case .refused(_, .openAccessibilitySettings) = await run(rig, request("", submitOverride: .return)).0 else {
            Issue.record("expected a refusal that opens Accessibility settings")
            return
        }
        #expect(rig.submitted.isEmpty)
    }

    @Test func aReturnOnlyCommandStoppedAtTheLimitIsNotPressed() async {
        let rig = Rig()
        let (result, _) = await run(rig, request("", submitOverride: .return, stoppedAtLimit: "5-minute"))
        #expect(result == .refused(message: "Stopped at the 5-minute limit — Return not pressed", action: nil))
        #expect(rig.submitted.isEmpty)
    }

    @Test func nothingSaidIsNoSpeech() async {
        #expect(await run(Rig(), request("", heard: "")).0 == .done(.noSpeech))
    }
}
