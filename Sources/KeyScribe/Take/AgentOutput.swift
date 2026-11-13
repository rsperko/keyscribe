import Foundation
import KeyScribeKit

@MainActor
final class AgentOutput {
    private struct AwaitedReceipt {
        var entry: (id: String, at: Date)?
        var early: [AgentReceipt] = []
        var delivery: HistoryEntry.Fact?
    }

    private let hud: HUDChannel
    private let reporter: TakeReporter
    var keepsHistory: @MainActor () -> Bool = { false }
    var noticesBlocked: @MainActor () -> Bool = { false }
    var hide: @MainActor (Double) -> Void = { _ in }
    private var pendingNotices: [AgentReceipt] = []
    private var awaited: [String: AwaitedReceipt] = [:]
    private var recordedTakes: [(request: String, id: String, at: Date)] = []
    private static let rememberedTakes = 64
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
        _ text: String, to id: String, via agents: AgentHub, images: [String] = []
    ) async -> (request: String, receipt: AgentReceipt) {
        let request = UUID().uuidString
        awaited[request] = AwaitedReceipt()
        return (request, await agents.deliver(text, to: id, request: request, images: images))
    }

    func noteRecorded(_ entry: HistoryEntry, request: String) {
        guard let id = entry.id else { return }
        awaited[request]?.entry = (id, entry.timestamp)
        recordedTakes.append((request, id, entry.timestamp))
        if recordedTakes.count > Self.rememberedTakes { recordedTakes.removeFirst(recordedTakes.count - Self.rememberedTakes) }
    }

    func recordSpokenReply(
        _ heard: SpokenResultOutput.Heard, at now: Date = Date(), alone: () -> (mode: String, retentionDays: Int)?,
        then saved: @escaping @MainActor (_ entry: String?) -> Void = { _ in }
    ) {
        guard keepsHistory(), reporter.keepsHistory else { return saved(nil) }
        let reply = HistoryEntry.SpokenReply(
            at: now, conversation: heard.name, text: heard.text, connection: heard.connection, voice: heard.reader?.rawValue,
            reason: heard.reason, returned: heard.returned, failure: heard.failure)
        if let origin = heard.origin {
            guard let take = recordedTakes.last(where: { $0.request == origin }) else { return saved(nil) }
            reporter.update(id: take.id, near: take.at, { current in
                var next = current
                next.spokenReply = reply
                return next
            }, then: { saved($0 ? take.id : nil) })
            return
        }
        guard let alone = alone() else { return saved(nil) }
        let id = UUID().uuidString
        reporter.append(
            AgentHistoryFacts.spokenReplyEntry(id: id, mode: alone.mode, reply: reply),
            retentionDays: alone.retentionDays, then: { saved($0 ? id : nil) })
    }

    func recordUnreadReply(_ unread: SpokenResultOutput.Unread, origin: String, at now: Date = Date()) {
        guard keepsHistory(), reporter.keepsHistory, let take = recordedTakes.last(where: { $0.request == origin }) else { return }
        reporter.update(id: take.id, near: take.at, { Self.adding(step: unread.line, at: now, to: $0) }, then: { _ in })
    }

    nonisolated private static func adding(step text: String, at now: Date, to current: HistoryEntry) -> HistoryEntry {
        var next = current
        next.steps = (current.steps ?? [.init(at: current.timestamp, text: current.summary ?? "")]) + [.init(at: now, text: text)]
        return next
    }

    func recordDelivery(_ fact: HistoryEntry.Fact, request: String) {
        guard let tracked = awaited[request] else { return }
        guard let entry = tracked.entry else {
            awaited[request]?.delivery = fact
            return
        }
        guard keepsHistory(), reporter.keepsHistory else { return }
        reporter.update(id: entry.id, near: entry.at, { AgentHistoryFacts.replacing(fact, in: $0) }, then: { _ in })
    }

    func replayEarlyReceipts(request: String, receipt: AgentReceipt) {
        if let fact = awaited[request]?.delivery, awaited[request]?.entry != nil {
            awaited[request]?.delivery = nil
            recordDelivery(fact, request: request)
        }
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
            var next = Self.adding(step: summary, at: now, to: current)
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

    static func spokenRefusal(_ receipt: AgentReceipt) -> String? {
        switch receipt {
        case .sent, .queued, .uncertain: return nil
        case .kept(let handle, let reason):
            switch reason {
            case .composing: return "\(handle) didn\u{2019}t take that: its prompt box has text"
            case .typedSince: return "\(handle) didn\u{2019}t take that: you sent it a message since"
            case .interrupted: return "\(handle) didn\u{2019}t take that: its last turn was stopped"
            case .dialog: return "\(handle) didn\u{2019}t take that: it has a dialog open"
            case .connectionGap: return "\(handle) didn\u{2019}t take that: it lost its connection"
            case .inPromptBox: return "\(handle) has your message in its prompt box. Press Return there to send it."
            }
        case .notSent(let handle, let reason):
            let it = handle == nil ? "the conversation" : "it"
            let why = switch reason {
            case .conversationEnded: "\(it) has ended"
            case .connectorNotRunning: "\(it) isn\u{2019}t connected"
            case .conversationChanged: "\(it) switched conversations"
            case .stopped: "after a stopped turn \(it) takes only typed messages"
            case .expired: "\(it) timed out"
            case .refused: "\(it) wouldn\u{2019}t accept it"
            case .disconnected: "\(it)\u{2019}s disconnected"
            }
            return handle.map { "\($0) didn\u{2019}t take that: \(why)" } ?? "Your message wasn\u{2019}t sent: \(why)"
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

    static func either(_ items: [String], joining word: String = "or") -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " \(word) " + last
    }

    enum Retry {
        case tell, ask, open, select

        func phrase(_ name: String) -> String {
            switch self {
            case .select: "select \(name)"
            case .tell: "tell \(name), \u{2026}"
            case .ask: "ask \(name), \u{2026}"
            case .open: "open \(name)"
            }
        }

        static func matching(_ text: String, _ address: AgentAddress) -> Retry {
            if case .open = address { return .open }
            if case .select = address { return .select }
            return AgentAddress.asks(text) ? .ask : .tell
        }
    }

    static func openAskLine(_ reason: AgentRecipient.AskReason, retry: Retry? = nil, names: [String: String] = [:], current: String? = nil) -> String {
        if case .sayToSelect(let name) = reason { return selectHint(name) }
        let advice = [askAdvice(reason), retryHint(reason, retry: retry, names: names, current: current)].compactMap { $0 }
        guard !advice.isEmpty else {
            let problem = askProblem(reason)
            return problem.prefix(1).uppercased() + problem.dropFirst()
        }
        return ([sentence(askProblem(reason))] + advice).joined(separator: " ")
    }

    static func askLine(_ reason: AgentRecipient.AskReason, retry: Retry? = nil, names: [String: String] = [:], current: String? = nil) -> String {
        if case .sayToSelect(let name) = reason { return selectHint(name) }
        let advice = [askAdvice(reason), retryHint(reason, retry: retry, names: names, current: current)].compactMap { $0 }
        return ([sentence(askProblem(reason)), nothingSent] + advice).joined(separator: " ")
    }

    private static func sentence(_ text: String) -> String {
        let capitalized = text.prefix(1).uppercased() + text.dropFirst()
        return capitalized.hasSuffix("?") || capitalized.hasSuffix(".") ? capitalized : capitalized + "."
    }

    private static func askAdvice(_ reason: AgentRecipient.AskReason) -> String? {
        switch reason {
        case .noBreak(let name): "Say \u{201C}tell \(name),\u{201D} with a pause, or \u{201C}tell \(name) to \u{2026}\u{201D}."
        case .sharedName(_, _, let surface?): "Name the panes in \(surface) to tell them apart."
        default: nil
        }
    }

    private static func selectHint(_ name: String) -> String {
        "Say \u{201C}select \(name)\u{201D} to choose it. Nothing sent."
    }

    static let nothingSent = "Nothing sent."
    static let keptHint = "Your words are kept for Paste last dictation."

    static func kept(_ line: String, body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? line : withHint(line, keptHint)
    }
    static let cancelledLine = "Cancelled. Nothing sent."

    static func withHint(_ line: String, _ hint: String) -> String {
        hint.isEmpty ? line : line + (line.hasSuffix(".") ? " " : ". ") + hint
    }

    static let unconnectedShown = 2

    static func unconnectedHint(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        let one = names.count == 1
        let shown = names.count > unconnectedShown + 1 ? Array(names.prefix(unconnectedShown)) + ["\(names.count - unconnectedShown) more"] : names
        return "\(either(shown, joining: "and")) \(one ? "is" : "are") running but not connected. Coding agent settings shows how to connect \(one ? "it" : "them")"
    }

    static func example(names: [String: String], current: String?) -> String? {
        let ordered = names.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ordered.first { names[$0] == current } ?? ordered.first
    }

    private static func retryHint(_ reason: AgentRecipient.AskReason, retry: Retry?, names: [String: String], current: String?) -> String? {
        guard let retry else { return nil }
        let name: String? = switch reason {
        case .unknownName: example(names: names, current: current)
        case .shownOn(_, let name, _): names[name] == nil ? nil : name
        default: nil
        }
        return name.map { "Try \u{201C}\(retry.phrase($0))\u{201D}" }
    }

    private static func askProblem(_ reason: AgentRecipient.AskReason) -> String {
        switch reason {
        case .noRecipient: "start with a conversation\u{2019}s name"
        case .noSuchRow(let row): "there is no conversation \(row)"
        case .sayToSelect(let name): "say \u{201C}select \(name)\u{201D} to choose it"
        case .unknownName(let name): "no conversation named \u{201C}\(name)\u{201D}"
        case .shownOn(let word, let name, let seenAs): "\u{201C}\(word)\u{201D} is the \(seenAs) of \u{201C}\(name)\u{201D}"
        case .soundsLike(let spoken, let name): "\u{201C}\(spoken)\u{201D} sounded like \u{201C}\(name)\u{201D}"
        case .noBreak(let name): "did you mean \u{201C}\(name)\u{201D}?"
        case .ambiguousName(let name, let matches):
            "\u{201C}\(name)\u{201D} could be \(Self.either(matches.map { "\u{201C}\($0)\u{201D}" }))"
        case .sharedName(let name, let matches, _):
            "\u{201C}\(name)\u{201D} could be \(Self.either(matches.map { "\u{201C}\($0)\u{201D}" }))"
        }
    }

    struct ClipboardNote: Equatable {
        var images = 0
        var files = 0
        var attached = false
        var missed = false

        static let missedLine = "the clipboard had nothing to insert, so \u{201C}insert clipboard contents\u{201D} went as words"

        var suffix: String {
            guard images + files > 0 else { return "" }
            if attached && files == 0 { return " with \(Self.count(images, "image"))" }
            let items = [images > 0 ? Self.count(images, "image") : nil, files > 0 ? Self.count(files, "file") : nil].compactMap { $0 }
            return " with the path\(images + files == 1 ? "" : "s") to \(items.joined(separator: " and "))"
        }

        private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
    }

    static func receiptState(
        _ receipt: AgentReceipt, mode: String, heard: String, settingsMode: String? = nil, clipboard: ClipboardNote = ClipboardNote()
    ) -> HUDState {
        switch receipt {
        case .sent(let handle):
            if clipboard.missed { return .advisory(message: "Sent to \(handle), but \(ClipboardNote.missedLine)") }
            return .commandDone(summary: "Sent to \(handle)\(clipboard.suffix)", detail: mode)
        case .queued(let handle, let reason):
            let respond = " Say \u{201C}open \(handle)\u{201D} to respond; this message stays queued"
            let detail = switch reason {
            case .working: "Sends when it finishes"
            case .approval: "Waiting for approval." + respond
            case .question: "Waiting for an answer." + respond
            case .userDialog: "Dialog open." + respond
            }
            let missed = clipboard.missed ? ". T" + ClipboardNote.missedLine.dropFirst() : ""
            return .commandDone(summary: "Queued for \(handle)\(clipboard.suffix)", detail: detail + missed)
        case .kept(let handle, let reason):
            let why = switch reason {
            case .typedSince: "you sent it a message since"
            case .composing: "its prompt box already has text. Send or clear that text there, then say this again"
            case .interrupted: "its last turn was stopped"
            case .dialog: "it has a dialog open"
            case .connectionGap: "it lost its connection to \(Branding.appName) while this waited"
            case .inPromptBox: "its last turn was interrupted, so the message is waiting in its prompt box. Press Return there to send it"
            }
            return .advisory(message: "Not sent to \(handle): \(why)")
        case .notSent(let handle, let reason):
            let name = handle ?? "That conversation"
            let message = switch reason {
            case .conversationEnded: "That conversation has ended. \(nothingSent)"
            case .connectorNotRunning: "\(name) isn\u{2019}t connected to \(Branding.appName). \(nothingSent)"
            case .conversationChanged: "\(name) switched to another conversation. \(nothingSent)"
            case .stopped: "\(name)\u{2019}s last turn was interrupted, so it takes only a message you type. \(nothingSent) Type one there, then dictate again."
            case .expired: "\(name) didn\u{2019}t take it in time. \(nothingSent)"
            case .refused: "\(name) refused the message. \(nothingSent)"
            case .disconnected: "\(name) is disconnected. \(nothingSent)"
            }
            let action: HUDErrorAction? = switch reason {
            case .connectorNotRunning, .disconnected: settingsMode.map { HUDErrorAction.openCodingAgents($0) }
            default: nil
            }
            return .error(message: message, action: action, heard: HeardExcerpt(heard: heard))
        case .uncertain(let handle):
            return .advisory(message: "May not have reached \(handle): check its terminal")
        }
    }
}
