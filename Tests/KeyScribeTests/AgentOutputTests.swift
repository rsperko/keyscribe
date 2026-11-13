import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct AgentOutputTests {
    private final class HUDSpy: HUDPresenting {
        var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    @Test func aNoticeThatNeedsAttentionShowsBeforeAQuieterOne() async {
        let spy = HUDSpy()
        let output = AgentOutput(hud: HUDChannel(hud: spy), reporter: TakeReporter(history: nil, replacementUsage: nil))
        output.noticeDelayOverride = .milliseconds(1)
        var hides: [Double] = []
        output.hide = { hides.append($0) }
        output.noticesBlocked = { true }
        output.showNotice(.sent("backend"))
        output.showNotice(.uncertain("frontend"))
        output.noticesBlocked = { false }
        for _ in 0..<200 where spy.states.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(spy.states.first == AgentOutput.receiptState(.uncertain("frontend"), mode: "Coding agent", heard: ""))
        #expect(hides.first == 4)
    }

    @Test func aReceiptThatArrivesBeforeItsEntryIsWrittenUpdatesTheEntryOnceItIs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-agent-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = HistoryStore(supportDir: dir)
        let reporter = TakeReporter(history: history, replacementUsage: nil)
        let updated = Signal()
        reporter.onHistoryUpdated = { updated.fire() }
        let output = AgentOutput(hud: HUDChannel(hud: nil), reporter: reporter)
        output.keepsHistory = { true }
        let hub = AgentHub(transport: NoTransport(), scan: { [] }, names: AgentNameStore(directory: dir))
        let (request, _) = await output.deliver("hi", to: "s1", via: hub)
        output.showNotice(.sent("backend"), request: request)
        var entry = HistoryEntry(
            id: UUID().uuidString, timestamp: Date(), modeName: "Coding agent", heard: "hi", result: "hi", outcome: .inserted,
            cloudInvolved: false, redaction: false, contextCategories: [])
        entry.summary = "Queued for backend"
        reporter.append(entry, retentionDays: 7, confirm: true)
        let written = try #require(history.entries().first)
        output.noteRecorded(written, request: request)
        output.replayEarlyReceipts(request: request, receipt: .queued("backend"))
        await updated.wait()
        #expect(history.entries().first?.summary == "Sent to backend")
    }

    @Test func aDeliveryRecordReplacesTheOneTheEntryHasAndOneArrivingBeforeTheEntryIsWrittenWaitsForIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-agent-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = HistoryStore(supportDir: dir)
        let reporter = TakeReporter(history: history, replacementUsage: nil)
        let updated = Signal()
        reporter.onHistoryUpdated = { updated.fire() }
        let output = AgentOutput(hud: HUDChannel(hud: nil), reporter: reporter)
        output.keepsHistory = { true }
        let hub = AgentHub(transport: NoTransport(), scan: { [] }, names: AgentNameStore(directory: dir))
        let (request, _) = await output.deliver("hi", to: "s1", via: hub)
        output.recordDelivery(.init(label: "Delivery", value: "early"), request: request)
        var entry = HistoryEntry(
            id: UUID().uuidString, timestamp: Date(), modeName: "Coding agent", heard: "hi", result: "hi", outcome: .failed,
            cloudInvolved: false, redaction: false, contextCategories: [])
        entry.facts = [.init(label: "Command", value: "Send message"), .init(label: "Delivery", value: "first")]
        reporter.append(entry, retentionDays: 7, confirm: true)
        let written = try #require(history.entries().first)
        output.noteRecorded(written, request: request)
        output.replayEarlyReceipts(request: request, receipt: .uncertain("backend"))
        await updated.wait()
        #expect(history.entries().first?.facts == [.init(label: "Command", value: "Send message"), .init(label: "Delivery", value: "early")])
        output.recordDelivery(.init(label: "Delivery", value: "later"), request: request)
        for _ in 0..<200 where history.entries().first?.facts?.last?.value != "later" { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(history.entries().first?.facts == [.init(label: "Command", value: "Send message"), .init(label: "Delivery", value: "later")])
    }

    private final class NoTransport: AgentTransport {
        func enqueue(_ command: AgentCommand, for session: String) {}
        func isLive(session: String) -> Bool { false }
        func forget(session: String) {}
        func withdraw(_ id: String) -> Bool { false }
    }
}
