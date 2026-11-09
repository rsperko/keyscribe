import Foundation
import KeyScribeKit

@MainActor
final class AgentOutput {
    private struct AwaitedReceipt {
        var entry: (id: String, at: Date)?
        var early: [AgentReceipt] = []
    }

    private let hud: HUDChannel
    private let reporter: TakeReporter
    var keepsHistory: @MainActor () -> Bool = { false }
    var noticesBlocked: @MainActor () -> Bool = { false }
    var hide: @MainActor (Double) -> Void = { _ in }
    private var pendingNotices: [AgentReceipt] = []
    private var awaited: [String: AwaitedReceipt] = [:]
    private var noticeTask: Task<Void, Never>?
    var noticeDelayOverride: Duration?

    static let deferredNoticeDelay: Duration = .milliseconds(2500)
    static let noticeRecheck: Duration = .milliseconds(500)
    private static let noticeSeconds: Double = 4

    init(hud: HUDChannel, reporter: TakeReporter) {
        self.hud = hud
        self.reporter = reporter
    }

    func forgetReceipts() {
        awaited = [:]
    }

    func deliver(
        _ text: String, to id: String, via agents: AgentHub
    ) async -> (request: String, receipt: AgentReceipt) {
        let request = UUID().uuidString
        awaited[request] = AwaitedReceipt()
        return (request, await agents.deliver(text, to: id, request: request))
    }

    func noteRecorded(_ entry: HistoryEntry, request: String) {
        guard let id = entry.id else { return }
        awaited[request]?.entry = (id, entry.timestamp)
    }

    func replayEarlyReceipts(request: String, receipt: AgentReceipt) {
        guard let tracked = awaited[request], tracked.entry != nil,
              !tracked.early.isEmpty || Self.mayStillSettle(receipt) else { return stopAwaiting(request) }
        awaited[request]?.early = []
        for receipt in tracked.early { recordLateReceipt(receipt, request: request) }
    }

    func showNotice(_ receipt: AgentReceipt, request: String? = nil) {
        if let request { recordLateReceipt(receipt, request: request) }
        pendingNotices.append(receipt)
        flushNotices(afterWaiting: false)
    }

    func forgetReceipt(request: String) {
        stopAwaiting(request)
    }

    private func stopAwaiting(_ request: String) {
        awaited[request] = nil
    }

    private func recordLateReceipt(_ receipt: AgentReceipt, request: String) {
        guard let tracked = awaited[request] else { return }
        guard let entry = tracked.entry else {
            awaited[request]?.early.append(receipt)
            return
        }
        guard keepsHistory(), reporter.keepsHistory,
              let summary = Self.receiptState(receipt, mode: "", heard: "").primaryText else { return stopAwaiting(request) }
        let failed = Self.dictationOutcome(receipt) == .failed
        if !Self.mayStillSettle(receipt) { stopAwaiting(request) }
        let now = Date()
        reporter.update(id: entry.id, near: entry.at, { current in
            var next = current
            next.steps = (current.steps ?? [.init(at: current.timestamp, text: current.summary ?? "")]) + [.init(at: now, text: summary)]
            next.summary = summary
            next.outcome = failed ? .failed : current.keptLocalText ? .localFallback : .inserted
            next.failureReason = failed ? summary : nil
            return next
        }, then: { [weak self] changed in
            if !changed { self?.stopAwaiting(request) }
        })
    }

    private func flushNotices(afterWaiting waited: Bool) {
        guard !pendingNotices.isEmpty, noticeTask == nil else { return }
        if noticesBlocked() || waited {
            let blocked = noticesBlocked()
            noticeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.noticeDelayOverride ?? (blocked ? Self.noticeRecheck : Self.deferredNoticeDelay))
                guard let self else { return }
                self.noticeTask = nil
                if blocked || self.noticesBlocked() {
                    self.flushNotices(afterWaiting: true)
                } else {
                    self.presentNotices()
                }
            }
            return
        }
        presentNotices()
    }

    private func presentNotices() {
        let attention = pendingNotices.filter(Self.needsAttention)
        guard let receipt = attention.first ?? pendingNotices.last else { return }
        pendingNotices = Array(attention.dropFirst())
        hud.present(Self.receiptState(receipt, mode: "Coding agent", heard: ""))
        hide(Self.noticeSeconds)
        guard !pendingNotices.isEmpty else { return }
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.noticeDelayOverride ?? .seconds(Self.noticeSeconds))
            self?.noticeTask = nil
            self?.flushNotices(afterWaiting: false)
        }
    }

    private static func needsAttention(_ receipt: AgentReceipt) -> Bool {
        switch receipt {
        case .notSent, .kept, .uncertain: true
        case .sent, .queued: false
        }
    }

    static func dictationOutcome(_ receipt: AgentReceipt) -> DictationOutcome {
        switch receipt {
        case .sent, .queued, .kept: .inserted
        case .notSent, .uncertain: .failed
        }
    }

    private static func mayStillSettle(_ receipt: AgentReceipt) -> Bool {
        switch receipt {
        case .queued, .uncertain: true
        case .sent, .kept, .notSent: false
        }
    }

    private static func either(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " or " + last
    }

    static func openAskLine(_ reason: AgentRecipient.AskReason) -> String {
        let problem = askProblem(reason)
        return problem.prefix(1).uppercased() + problem.dropFirst()
    }

    static func askLine(_ reason: AgentRecipient.AskReason) -> String {
        "Not sent: " + askProblem(reason)
    }

    private static func askProblem(_ reason: AgentRecipient.AskReason) -> String {
        switch reason {
        case .noRecipient: "start with a conversation\u{2019}s name"
        case .noSuchRow(let row): "there is no session \(row)"
        case .unknownName(let name): "no conversation named \u{201C}\(name)\u{201D}"
        case .soundsLike(let spoken, let name): "\u{201C}\(spoken)\u{201D} sounded like \u{201C}\(name)\u{201D}"
        case .noBreak(let name):
            "did you mean \u{201C}\(name)\u{201D}? Say \u{201C}tell \(name),\u{201D} with a pause, or \u{201C}tell \(name) to \u{2026}\u{201D}"
        case .ambiguousName(let name, let matches):
            "\u{201C}\(name)\u{201D} could be \(Self.either(matches.map { "\u{201C}\($0)\u{201D}" }))"
        case .sharedName(let name, let matches, let surface):
            "\u{201C}\(name)\u{201D} could be \(Self.either(matches.map { "\u{201C}\($0)\u{201D}" }))"
                + (surface.map { ". Name the panes in \($0) to tell them apart." } ?? "")
        }
    }

    static func receiptState(_ receipt: AgentReceipt, mode: String, heard: String, settingsMode: String? = nil) -> HUDState {
        switch receipt {
        case .sent(let handle):
            return .commandDone(summary: "Sent to \(handle)", detail: mode)
        case .queued(let handle, let reason):
            let respond = " Say \u{201C}open \(handle)\u{201D} to respond; this message stays queued"
            let detail = switch reason {
            case .working: "Sends when it finishes"
            case .approval: "Waiting for approval." + respond
            case .question: "Waiting for an answer." + respond
            case .userDialog: "Dialog open." + respond
            }
            return .commandDone(summary: "Queued for \(handle)", detail: detail)
        case .kept(let handle, let reason):
            let why = switch reason {
            case .typedSince: "you sent it a message since"
            case .composing: "it has a message you haven\u{2019}t sent"
            case .interrupted: "its last turn was stopped"
            case .dialog: "it has a dialog open"
            case .connectionGap: "it lost its connection to \(Branding.appName) while this waited"
            }
            return .advisory(message: "Not sent to \(handle): \(why)")
        case .notSent(let handle, let reason):
            let name = handle ?? "that conversation"
            let message = switch reason {
            case .conversationEnded: "Not sent: that conversation has ended"
            case .connectorNotRunning: "Not sent: \(name) isn\u{2019}t connected to \(Branding.appName)"
            case .conversationChanged: "Not sent: \(name) switched to another conversation"
            case .stopped: "Not sent: \(name) is stopped until you type in it"
            case .expired: "Not sent: \(name) didn\u{2019}t take it in time"
            case .refused: "Not sent: \(name) refused the message"
            case .disconnected: "Not sent: \(name) is disconnected"
            }
            let action: HUDErrorAction? = switch reason {
            case .connectorNotRunning, .disconnected: settingsMode.map(HUDErrorAction.openCodingAgents)
            default: nil
            }
            return .error(message: message, action: action, heard: HeardExcerpt(heard: heard))
        case .uncertain(let handle):
            return .advisory(message: "May not have reached \(handle): check its terminal")
        }
    }
}
