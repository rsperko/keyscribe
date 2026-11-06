import Foundation
import KeyScribeKit

protocol AgentTransport: AnyObject {
    func enqueue(_ command: AgentCommand, for session: String)
    func isLive(session: String) -> Bool
    func withdraw(_ id: String) -> Bool
}

extension AgentBridgeServer: AgentTransport {
    func enqueue(_ command: AgentCommand, for session: String) {
        enqueue(command, for: session, instance: nil)
    }
}

enum AgentReceipt: Equatable {
    enum KeptReason: Equatable { case draft, composing, typedSince, interrupted, questionResolved, historyMoved, connectionGap }
    enum NotSentReason: Equatable { case conversationEnded, connectorNotRunning, conversationChanged, stopped, refused(String) }

    case sent(String)
    case queued(String)
    case kept(String, reason: KeptReason)
    case notSent(String?, reason: NotSentReason)
    case uncertain(String)
}

@MainActor
final class AgentHub {
    private struct Request {
        let message: AgentOutbox.Message
        let handle: String
        var timedOut = false
    }

    static let runningGrace: TimeInterval = 5
    static let recentLimit = 20

    var onNotice: ((AgentReceipt, _ request: String) -> Void)?
    var onChange: (() -> Void)?
    private(set) var directory = AgentDirectory()
    private(set) var namesProblem: String?
    private(set) var current: String?
    private(set) var unsent: [AgentOutbox.Message] = []
    private(set) var recent: [AgentReceipt] = []

    private let transport: AgentTransport
    private let nameStore: AgentNameStore?
    private let focus: AgentTerminalFocusing?
    private let scan: () -> [ClaudeRegistryEntry]
    private let transcriptTitle: ((ClaudeRegistryEntry, Bool) -> ClaudeTranscriptTitle)?
    private let forgetTitles: ((Set<String>) -> Void)?
    private let receiptTimeout: Duration
    private let makeId: () -> String
    private let now: () -> Date
    private var outbox = AgentOutbox()
    private var requests: [String: Request] = [:]
    private var waiters: [String: CheckedContinuation<AgentReceipt, Never>] = [:]
    private var focusWaiters: [String: CheckedContinuation<TerminalSelection, Never>] = [:]
    private var features: [String: Set<String>] = [:]
    private var prompts: [String: Int] = [:]
    private var connectorNames: [String: String?] = [:]
    private var registryNames: [String: String?] = [:]
    private var labels: [String: String] = [:]
    private var handingOff: [String: String] = [:]
    private var running: [String: Date] = [:]
    private var lastUsed: [String: Date] = [:]

    init(
        transport: AgentTransport, scan: @escaping () -> [ClaudeRegistryEntry], names: AgentNameStore? = nil,
        focus: AgentTerminalFocusing? = nil, transcriptTitles: ClaudeTranscriptTitles? = nil, receiptTimeout: Duration = .seconds(8),
        now: @escaping () -> Date = Date.init, makeId: @escaping () -> String = { UUID().uuidString }
    ) {
        self.transport = transport
        nameStore = names
        self.focus = focus
        self.scan = scan
        transcriptTitle = transcriptTitles.map { titles in { titles.titles(for: $0, rereading: $1) } }
        forgetTitles = transcriptTitles.map { titles in { titles.forget(keeping: $0) } }
        self.receiptTimeout = receiptTimeout
        self.now = now
        self.makeId = makeId
        adopt(names?.load() ?? .names([:]))
    }

    struct NamesUnavailable: LocalizedError {
        var errorDescription: String? { "Names are off until they can be loaded." }
    }

    var names: [String: String] {
        guard namesProblem == nil else { return [:] }
        return Dictionary(directory.conversations.map { ($0.handle, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    var rows: [String] { directory.conversations.map(\.id) }

    func handle(of id: String) -> String? {
        directory.conversations.first { $0.id == id }?.handle
    }

    var recordingOrder: [AgentConversation] {
        AgentRoster.recordingOrder(directory.conversations, current: current, lastUsed: lastUsed)
    }

    func makeCurrent(_ id: String) {
        lastUsed[id] = now()
        guard current != id else { return }
        current = id
        onChange?()
    }

    func open(_ id: String, asking: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async -> AgentFocusResult {
        guard let conversation = directory.conversations.first(where: { $0.id == id }) else { return .none }
        makeCurrent(id)
        return await focus?.focus(session: id, pid: conversation.pid, asking: asking) ?? .none
    }

    static let focusTimeout: Duration = .seconds(3)

    func focusInPlace(_ session: String, within timeout: Duration = focusTimeout) async -> TerminalSelection {
        guard transport.isLive(session: session), let features = features[session] else { return .notFound }
        guard features.contains("focus") else { return .outdated }
        let id = makeId()
        let expiresAt = now().addingTimeInterval(TimeInterval(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: .notFound) }
                focusWaiters[id] = continuation
                transport.enqueue(.focus(id: id, expectedSession: session, expiresAt: expiresAt), for: session)
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.abandonFocus(id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.abandonFocus(id) }
        }
    }

    private func abandonFocus(_ id: String) {
        guard let waiter = focusWaiters.removeValue(forKey: id) else { return }
        _ = transport.withdraw(id)
        waiter.resume(returning: .notFound)
    }

    func rename(_ id: String, to name: String) throws {
        guard namesProblem == nil else { throw NamesUnavailable() }
        guard handle(of: id) != nil else { return }
        var renamed = directory
        try renamed.rename(id, to: name)
        try nameStore?.save(renamed.chosenNames)
        directory = renamed
        sendLabels()
        onChange?()
    }

    func reloadNames() {
        guard let nameStore, namesProblem != nil else { return }
        adopt(nameStore.load())
        refresh()
        onChange?()
    }

    private func adopt(_ loaded: AgentNameStore.Loaded) {
        switch loaded {
        case .names(let chosen):
            directory = AgentDirectory(chosen: chosen)
            namesProblem = nil
        case .unavailable(let reason):
            namesProblem = reason
            Log.agents.error("conversation names unavailable: \(reason, privacy: .public)")
        }
    }

    func refresh(nameReportedFor: String? = nil, rereadingTitles: Bool = true) {
        let entries = scan()
        let live = Set(entries.map(\.sessionId).filter(transport.isLive(session:)))
        let before = directory.revision
        var shown: [String: String] = [:]
        var nativeNames: [String: String?] = [:]
        for entry in entries {
            let id = entry.sessionId
            let recorded = transcriptTitle?(entry, rereadingTitles) ?? .init()
            if nameReportedFor != id, let previous = registryNames[id], previous != entry.explicitName {
                connectorNames[id] = nil
            }
            registryNames[id] = .some(entry.explicitName)
            let native: String?
            if let reported = connectorNames[id] {
                native = reported
            } else {
                native = entry.explicitName ?? recorded.explicitName
            }
            nativeNames[id] = .some(native)
            shown[id] = native ?? recorded.generatedTitle
        }
        forgetTitles?(Set(entries.map(\.sessionId)))
        directory.update(claude: entries, live: live, titles: shown, nativeNames: nativeNames)
        if let current, handle(of: current) == nil { self.current = nil }
        lastUsed = lastUsed.filter { handle(of: $0.key) != nil }
        sendLabels()
        let idle = Set(directory.conversations.filter { $0.state == .idle }.map(\.id))
        let stale = now().addingTimeInterval(-Self.runningGrace)
        running = running.filter { !idle.contains($0.key) || $0.value > stale }
        releaseHeld()
        if directory.revision != before { onChange?() }
    }

    private func sendLabels() {
        for conversation in directory.conversations where conversation.connectorLive {
            guard features[conversation.id]?.contains("label") == true else { continue }
            let label = "\u{201C}\(conversation.handle)\u{201D}"
            guard labels[conversation.id] != label else { continue }
            labels[conversation.id] = label
            transport.enqueue(.status(id: makeId(), expectedSession: conversation.id, text: label), for: conversation.id)
        }
    }

    func deliver(_ text: String, to id: String, delivery: Mode.Agent.Delivery, request: String? = nil) async -> AgentReceipt {
        guard let conversation = directory.conversations.first(where: { $0.id == id }) else {
            return .notSent(nil, reason: .conversationEnded)
        }
        lastUsed[id] = now()
        let message = AgentOutbox.Message(id: request ?? makeId(), conversation: id, text: text, delivery: delivery)
        let handle = conversation.handle
        switch outbox.send(message, state: state(of: id)) {
        case .handOff:
            return await withCheckedContinuation { continuation in
                waiters[message.id] = continuation
                handOff(message, handle: handle)
            }
        case .queue:
            return .queued(handle)
        case .draft:
            unsent.append(message)
            return .kept(handle, reason: .draft)
        case .needsReview(let reason):
            unsent.append(message)
            return .kept(handle, reason: Self.kept(reason))
        case .notSent(let reason):
            unsent.append(message)
            return .notSent(handle, reason: reason == .disconnected ? .connectorNotRunning : .conversationChanged)
        case .escRecovery:
            unsent.append(message)
            return .notSent(handle, reason: .stopped)
        }
    }

    func prepare(for hello: AgentEvent.Hello) {
        if hello.resumesAfterGap { outbox.noteConnectionGap(conversation: hello.session) }
        running[hello.session] = hello.knownIdle ? nil : now()
    }

    func handle(_ event: AgentEvent) {
        switch event {
        case .hello(let hello):
            features[hello.session] = Set(hello.features)
            prompts[hello.session] = hello.prompts
            labels[hello.session] = nil
            if let title = hello.title {
                connectorNames[hello.session] = .some(title.isEmpty ? nil : title)
            } else {
                connectorNames[hello.session] = nil
            }
            refresh(nameReportedFor: hello.session)
        case .title(let session, let text):
            connectorNames[session] = .some(text.isEmpty ? nil : text)
            refresh(nameReportedFor: session)
        case .focused(let request):
            focusWaiters.removeValue(forKey: request)?.resume(returning: .selected)
        case .ack:
            break
        case .submitted(let request, _):
            settle(request, .sent(requests[request]?.handle ?? ""), keep: false)
        case .refused(let request, _) where focusWaiters[request] != nil:
            focusWaiters.removeValue(forKey: request)?.resume(returning: .notFound)
        case .undelivered(let request, _, _) where focusWaiters[request] != nil:
            focusWaiters.removeValue(forKey: request)?.resume(returning: .notFound)
        case .refused(let request, "working"):
            clearHandOff(request)
            guard let entry = requests.removeValue(forKey: request) else { break }
            running[entry.message.conversation] = now()
            _ = outbox.send(entry.message, state: .working)
            report(.queued(entry.handle), for: request)
        case .refused(let request, "typedSince"):
            clearHandOff(request)
            settle(request, .kept(requests[request]?.handle ?? "", reason: .typedSince), keep: true)
            releaseHeld()
        case .refused(let request, "draft"):
            clearHandOff(request)
            settle(request, .kept(requests[request]?.handle ?? "", reason: .composing), keep: true)
            releaseHeld()
        case .refused(let request, let reason):
            clearHandOff(request)
            settle(request, .notSent(requests[request]?.handle, reason: Self.notSent(reason)), keep: true)
            releaseHeld()
        case .undelivered(let request, _, true):
            guard let entry = requests[request], !entry.timedOut else { break }
            requests[request]?.timedOut = true
            report(.uncertain(entry.handle), for: request)
        case .undelivered(let request, "connectionGap", false):
            clearHandOff(request)
            settle(request, .kept(requests[request]?.handle ?? "", reason: .connectionGap), keep: true)
            releaseHeld()
        case .undelivered(let request, _, false):
            clearHandOff(request)
            settle(request, .notSent(requests[request]?.handle, reason: .connectorNotRunning), keep: true)
            releaseHeld()
        case .typed(let session, let count):
            if let count { prompts[session] = count }
            outbox.noteTyped(conversation: session)
            if handle(of: session) != nil { makeCurrent(session) }
        case .turnStarted(let session, _):
            handingOff[session] = nil
            running[session] = now()
        case .turnComplete(let session, let reason, _):
            handingOff[session] = nil
            running[session] = nil
            if reason == "aborted" { outbox.noteInterrupted(conversation: session) }
            refresh()
        }
    }

    private func state(of id: String) -> AgentLiveState? {
        guard let conversation = directory.conversations.first(where: { $0.id == id }), conversation.connectorLive else { return nil }
        if handingOff[id] != nil || running[id] != nil { return .working }
        return conversation.state
    }

    private func handOff(_ message: AgentOutbox.Message, handle: String) {
        requests[message.id] = Request(message: message, handle: handle)
        handingOff[message.conversation] = message.id
        transport.enqueue(
            .submit(id: message.id, expectedSession: message.conversation, text: message.text, expectedPrompts: prompts[message.conversation]),
            for: message.conversation)
        let timeout = receiptTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, let entry = self.requests[message.id], !entry.timedOut else { return }
            self.requests[message.id]?.timedOut = true
            self.report(.uncertain(handle), for: message.id)
        }
    }

    private func clearHandOff(_ request: String) {
        guard let conversation = requests[request]?.message.conversation, handingOff[conversation] == request else { return }
        handingOff[conversation] = nil
    }

    private func settle(_ request: String, _ receipt: AgentReceipt, keep: Bool) {
        guard let entry = requests.removeValue(forKey: request) else { return }
        if keep { unsent.append(entry.message) }
        report(receipt, for: request)
    }

    private func report(_ receipt: AgentReceipt, for request: String) {
        recent.append(receipt)
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
        if let waiter = waiters.removeValue(forKey: request) {
            waiter.resume(returning: receipt)
        } else {
            onNotice?(receipt, request)
        }
    }

    private func releaseHeld() {
        for release in outbox.release(state: state(of:)) {
            let handle = handle(of: release.message.conversation)
            switch release.decision {
            case .handOff:
                handOff(release.message, handle: handle ?? "")
            case .needsReview(let reason):
                unsent.append(release.message)
                report(.kept(handle ?? "", reason: Self.kept(reason)), for: release.message.id)
            case .notSent(let reason):
                unsent.append(release.message)
                report(.notSent(handle, reason: reason == .disconnected ? .connectorNotRunning : .conversationChanged), for: release.message.id)
            case .queue, .draft, .escRecovery:
                unsent.append(release.message)
                report(.notSent(handle, reason: .stopped), for: release.message.id)
            }
        }
    }

    private static func kept(_ reason: AgentDeliveryDecision.ReviewReason) -> AgentReceipt.KeptReason {
        switch reason {
        case .typedSince: .typedSince
        case .questionResolved: .questionResolved
        case .interrupted: .interrupted
        case .historyMoved: .historyMoved
        case .connectionGap: .connectionGap
        }
    }

    private static func notSent(_ reason: String) -> AgentReceipt.NotSentReason {
        if reason == "sessionChanged" { return .conversationChanged }
        if reason.contains("the session was stopped") { return .stopped }
        return .refused(reason)
    }
}

@MainActor
final class AgentRuntime {
    private final class HubBox: @unchecked Sendable { weak var hub: AgentHub? }

    let hub: AgentHub
    private let server: AgentBridgeServer
    private var timer: Timer?

    static func bridgeDirectory(supportDir: URL) -> URL {
        supportDir.appendingPathComponent("agents", isDirectory: true)
    }

    init(supportDir: URL, claudeConfigDirs: [URL] = [ClaudeRegistryScanner.defaultConfigDir()]) throws {
        let directory = Self.bridgeDirectory(supportDir: supportDir)
        let token = try AgentBridgeToken.loadOrCreate(in: directory)
        let box = HubBox()
        server = AgentBridgeServer(
            directory: directory, token: token,
            installation: { ClaudeConnectorInstaller.currentInstallation(in: directory) },
            onHello: { hello, done in
                Task { @MainActor in
                    box.hub?.prepare(for: hello)
                    done()
                }
            }
        ) { event in
            Task { @MainActor in box.hub?.handle(event) }
        }
        hub = AgentHub(
            transport: server, scan: { ClaudeRegistryScanner.scan(configDirs: claudeConfigDirs) },
            names: AgentNameStore(directory: directory),
            focus: AgentTerminalFocus(connector: { session in await box.hub?.focusInPlace(session) ?? .notFound }),
            transcriptTitles: ClaudeTranscriptTitles(configDirs: claudeConfigDirs))
        box.hub = hub
        try server.start()
        hub.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak hub] _ in
            MainActor.assumeIsolated { hub?.refresh(rereadingTitles: false) }
        }
    }

    func retire() {
        server.retire()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        server.stop()
    }
}
