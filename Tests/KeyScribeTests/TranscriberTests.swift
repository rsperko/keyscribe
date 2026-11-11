import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct TranscriberTests {
    @Test func aGateThatKeepsRejectingIsRebuiltAfterTheStreakLimit() {
        let transcriber = Transcriber()
        let wedged = transcriber.gate
        transcriber.noteBusyRejection()
        transcriber.noteBusyRejection()
        #expect(transcriber.gate === wedged)
        transcriber.noteBusyRejection()
        #expect(transcriber.gate !== wedged)
    }

    @Test func aSuccessBetweenRejectionsStartsTheStreakOver() {
        let transcriber = Transcriber()
        let gate = transcriber.gate
        transcriber.noteBusyRejection()
        transcriber.noteBusyRejection()
        transcriber.resetBusyStreak()
        transcriber.noteBusyRejection()
        #expect(transcriber.gate === gate)
    }

    @Test func eachRecoveryDecisionIsReportedAsOneLine() {
        let transcriber = Transcriber()
        var lines: [String] = []
        transcriber.recoveryObserver = { lines.append($0) }
        final class Engine: SpeechEngine, @unchecked Sendable {
            let id = "e"
            let displayName = "E"
            let supportsRecognitionBias = false
            func loadIfNeeded() async throws {}
            func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "" }
            func evict() async {}
        }
        transcriber.logRecovery(
            engine: Engine(), audioSeconds: 2, reading: nil,
            decision: .init(attempted: true, outcome: "retry-deadline"))
        #expect(lines.count == 1)
        #expect(lines.first?.contains("outcome=retry-deadline") == true)
    }
}
