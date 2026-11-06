import Carbon
import Foundation
import Testing
@testable import KeyScribeApp

struct AutomationConsentTests {
    private final class Verdicts: @unchecked Sendable {
        private let lock = NSLock()
        private let checked: [String: AutomationVerdict]
        private let answered: [String: AutomationVerdict]
        private var calls: [String] = []
        private let hold = DispatchSemaphore(value: 0)
        private let holding: Set<String>

        init(checked: [String: AutomationVerdict], answered: [String: AutomationVerdict] = [:], holding: Set<String> = []) {
            self.checked = checked
            self.answered = answered
            self.holding = holding
        }

        var log: [String] { lock.withLock { calls } }
        func release() { for _ in holding { hold.signal() } }

        var verdict: @Sendable (String, Bool) -> AutomationVerdict {
            { [self] id, asking in
                lock.withLock { calls.append("\(id)\(asking ? "?" : "")") }
                guard asking else { return checked[id] ?? .unknown }
                if holding.contains(id) { hold.wait() }
                return answered[id] ?? .needsAsking
            }
        }
    }

    private func settle(_ ids: [String], _ verdicts: Verdicts, answerWithin: TimeInterval = 1) async -> AutomationConsent.Settled {
        await AutomationConsent.settle(
            ids, queue: DeadlineQueue(label: "test.consent"), checkWithin: 1, answerWithin: answerWithin,
            verdict: verdicts.verdict)
    }

    @Test func aBrowserAlreadyDecidedIsNeverAsked() async {
        let verdicts = Verdicts(checked: ["a": .allowed, "b": .unknown, "c": .denied])
        let settled = await settle(["a", "b", "c"], verdicts)
        #expect(settled == .init(readable: ["a", "b"], refused: ["c"], unanswered: []))
        #expect(verdicts.log == ["a", "b", "c"])
    }

    @Test func aBrowserThatNeedsConsentIsAskedAndItsAnswerIsUsed() async {
        let verdicts = Verdicts(checked: ["a": .needsAsking, "b": .needsAsking], answered: ["a": .allowed, "b": .denied])
        let settled = await settle(["a", "b"], verdicts)
        #expect(settled == .init(readable: ["a"], refused: ["b"], unanswered: []))
        #expect(verdicts.log == ["a", "a?", "b", "b?"])
    }

    @Test func aCheckThatMayNotAskLeavesAnUndecidedAppUnansweredWithoutAsking() async {
        let verdicts = Verdicts(checked: ["a": .allowed, "b": .needsAsking, "c": .unknown, "d": .denied], answered: ["b": .allowed])
        let announced = Verdicts(checked: [:])
        let settled = await AutomationConsent.settle(
            ["a", "b", "c", "d"], queue: DeadlineQueue(label: "test.consent"), checkWithin: 1, answerWithin: 1, mayAsk: false,
            verdict: verdicts.verdict, willAsk: { _ = announced.verdict($0, false) })
        #expect(settled == .init(readable: ["a"], refused: ["d"], unanswered: ["b", "c"]))
        #expect(verdicts.log == ["a", "b", "c", "d"])
        #expect(announced.log.isEmpty)
    }

    @Test func onlyAnAppAboutToBeAskedIsAnnouncedBeforeTheQuestion() async {
        let verdicts = Verdicts(checked: ["a": .allowed, "b": .needsAsking], answered: ["b": .allowed])
        let announced = Verdicts(checked: [:])
        _ = await AutomationConsent.settle(
            ["a", "b"], queue: DeadlineQueue(label: "test.consent"), checkWithin: 1, answerWithin: 1,
            verdict: verdicts.verdict, willAsk: { _ = announced.verdict($0, false) })
        #expect(announced.log == ["b"])
    }

    @Test func aPromptLeftUnansweredIsNotRead() async {
        let verdicts = Verdicts(checked: ["a": .needsAsking], answered: ["a": .allowed], holding: ["a"])
        let settled = await settle(["a"], verdicts, answerWithin: 0.05)
        verdicts.release()
        #expect(settled == .init(readable: [], refused: [], unanswered: ["a"]))
    }
}

struct PinnedAppleScriptConsentTests {
    @Test func aScriptThatMayNotPromptSendsEveryEventWithoutAskingForConsent() {
        let mode = AESendMode(kAEWaitReply)
        #expect(PinnedAppleScript.sendMode(mode, prompting: false) == mode | AESendMode(kAEDoNotPromptForUserConsent))
        #expect(PinnedAppleScript.sendMode(mode, prompting: true) == mode)
    }
}
