import Foundation
import KeyScribeKit

protocol AgentTransport: AnyObject {
    func enqueue(_ command: AgentCommand, for session: String)
    func isLive(session: String) -> Bool
    func withdraw(_ id: String) -> Bool
    func forget(session: String)
}

extension AgentBridgeServer: AgentTransport {
    func enqueue(_ command: AgentCommand, for session: String) {
        enqueue(command, for: session, instance: nil)
    }
}

enum AgentReceipt: Equatable {
    enum KeptReason: Equatable { case composing, typedSince, interrupted, connectionGap, dialog, inPromptBox }
    enum NotSentReason: Equatable { case conversationEnded, connectorNotRunning, conversationChanged, stopped, expired, disconnected, refused(String) }

    case sent(String)
    case queued(String, waitingOn: AgentDeliveryDecision.QueueReason = .working)
    case kept(String, reason: KeptReason)
    case notSent(String?, reason: NotSentReason)
    case uncertain(String)
}

@MainActor
final class AgentHub {
    private struct Request {
        let message: AgentOutbox.Message
        let handle: String
        let attempt: Int
        let retry: Int
        var timedOut = false
        var check: String?
        var turnDuringHandOff: TurnDuringHandOff?
        var followsNextTurn = false
        var typedSince = false

        var wire: String { retry == 0 ? message.id : "\(message.id)~\(retry)" }
    }

    private enum TurnDuringHandOff {
        case started(String)
        case ended
    }

    private struct Traced {
        var conversation: String
        var delivery: AgentDelivery
    }

    static let runningGrace: TimeInterval = 5
    static let defaultCheckWait: Duration = .seconds(2)
    private static let keptDeliveries = 64

    var onNotice: ((AgentReceipt, _ request: String, _ conversation: String) -> Void)?
    var onForget: ((_ request: String) -> Void)?
    var onChange: (() -> Void)?
    var onFirstConnection: (() -> Void)?
    var onResult: ((_ conversation: String, _ handle: String, _ answer: String, _ requested: Bool, _ origin: String?) -> Void)?
    var onEnded: ((_ conversation: String, _ handle: String, _ body: String, _ requested: Bool, _ origin: String?) -> Void)?
    var onAttention: ((_ conversation: String, _ handle: String, _ attention: AgentAttention?, _ requested: Bool) -> Void)?
    var onWithdraw: ((_ conversation: String) -> Void)?
    var onDelivery: ((_ request: String, _ fact: HistoryEntry.Fact) -> Void)?
    private var traced: [String: Traced] = [:]
    private var tracedOrder: [String] = []
    private var attempts = 0
    private var retries: [String: Int] = [:]
    var speaks: () -> Bool = { false }
    private var awaitingResult: [String: String] = [:]
    private var awaitedRequests: [String: String] = [:]
    private var nextTyped: [String: TypedTurn] = [:]
    private struct TypedTurn {
        var request: String
        var typedAt: Date?
    }
    var typedTurnWindow: TimeInterval = 5
    private var requested: Set<String> = []
    private var nextRequested: Set<String> = []
    private var attention: [String: AgentAttention] = [:]
    private var goneSince: [String: Date] = [:]
    private var awaitedHandles: [String: String] = [:]
    private var liveSessions: Set<String> = []
    private var waitingPrompts: [String: AgentPrompt] = [:]
    private(set) var directory = AgentDirectory()
    private(set) var namesProblem: String?
    private(set) var namesNotSaved: String?
    private(set) var discoveryProblems: [String: String] = [:]
    private var shownProblems: [String: String] = [:]
    private var lastScan: [String: [AgentSession]] = [:]
    private var lastExtras: [String: AgentScanExtras] = [:]
    private var staleAgents: Set<String> = []
    private var shownExtras: [String: AgentScanExtras] = [:]
    private var scanTask: Task<Void, Never>?
    private var rescanWanted = false
    private var rereadWanted = false
    private var outstanding: [String: Outstanding] = [:]
    private var connectorNamesAt: [String: Date] = [:]
    private var stopped = false
    private var savedRemembered: [String: RememberedName] = [:]
    private(set) var current: String?
    let exclusions: AgentExclusions
    private(set) var exclusionsNotSaved: String?
    var disconnected: [AgentConversation] { directory.disconnected }
    var onSilence: ((_ conversation: String) -> Void)?

    private let transport: AgentTransport
    private let nameStore: AgentNameStore?
    private let focus: AgentTerminalFocusing?
    private let front: AgentFronting?
    private let glance: AgentFronting?
    private let discoveries: [any AgentDiscovery]
    private let receiptTimeout: Duration
    private let handOffLimit: Duration
    private let checkWait: Duration
    private let makeId: () -> String
    private let now: () -> Date
    private var outbox = AgentOutbox()
    private var requests: [String: Request] = [:]
    private var waiters: [String: CheckedContinuation<AgentReceipt, Never>] = [:]
    private var focusWaiters: [String: CheckedContinuation<TerminalSelection, Never>] = [:]
    private var features: [String: Set<String>] = [:]
    private var installations: [String: String] = [:]
    private(set) var loadedVersions: [String: String] = [:]
    private var environments: [String: [String: String]] = [:]
    private var prompts: [String: Int] = [:]
    private var typedCounts: [String: Int] = [:]
    private var connectorNames: [String: String?] = [:]
    private var registryNames: [String: String?] = [:]
    private var labels: [String: String] = [:]
    private var handingOff: [String: String] = [:]
    private var running: [String: Date] = [:]
    private var lastUsed: [String: Date] = [:]

    init(
        transport: AgentTransport, discovery: [any AgentDiscovery], names: AgentNameStore? = nil,
        focus: AgentTerminalFocusing? = nil, front: AgentFronting? = nil, glance: AgentFronting? = nil,
        receiptTimeout: Duration = .seconds(8), handOffLimit: Duration = .seconds(30), checkWait: Duration = AgentHub.defaultCheckWait,
        disconnectGrace: Duration = AgentHub.defaultDisconnectGrace, scanDeadline: Duration = AgentHub.defaultScanDeadline, exclusions: AgentExclusions = AgentExclusions(nil),
        places: (any AgentPlaceReading)? = nil,
        now: @escaping () -> Date = Date.init, makeId: @escaping () -> String = { UUID().uuidString }
    ) {
        self.exclusions = exclusions
        self.transport = transport
        self.disconnectGrace = disconnectGrace
        self.scanDeadline = scanDeadline
        nameStore = names
        self.focus = focus
        self.front = front
        self.glance = glance
        discoveries = discovery
        self.receiptTimeout = receiptTimeout
        self.handOffLimit = handOffLimit
        self.checkWait = checkWait
        self.now = now
        self.makeId = makeId
        adopt(names?.load() ?? .names([:]))
        placeTracker = places.map { reader in
            AgentPlaceTracker(reader: reader, now: now) { [weak self] in self?.placeQueries ?? [] }
        }
        placeTracker?.onChange = { [weak self] in self?.refresh() }
    }

    private(set) var placeTracker: AgentPlaceTracker?

    private static func isGenerated(_ reported: String?, _ title: AgentTitle) -> Bool {
        guard let reported, let generated = title.generatedTitle, title.explicitName == nil else { return false }
        return AgentHandles.matchKey(reported) == AgentHandles.matchKey(generated)
    }

    private var placeQueries: [AgentPlaceQuery] {
        (directory.conversations + directory.disconnected).compactMap { conversation in
            AgentSessionID.split(conversation.id).map {
                AgentPlaceQuery(
                    id: conversation.id, agent: $0.agent, native: $0.native, pid: conversation.pid,
                    environment: environments[conversation.id] ?? [:], placed: placeTracker?.places[conversation.id] != nil)
            }
        }
    }

    func placesUnread(_ ids: [String]) -> Bool {
        placeTracker.map { !$0.unattempted(ids).isEmpty } ?? false
    }

    func readPlaces() {
        placeTracker?.request()
    }

    func tickPlaces(settingsOpen: Bool) {
        guard settingsOpen else { return }
        placeTracker?.tick()
    }

    var sharedNames: [String: AgentRecipient.SharedName] {
        guard namesProblem == nil else { return [:] }
        return directory.sharedPlaceNames
    }

    func defaultName(for id: String) -> AgentDirectory.DefaultName? {
        directory.defaultName(for: id)
    }

    func useDefaultName(_ id: String) throws {
        guard namesProblem == nil else { throw NamesUnavailable() }
        guard directory.chosenNames[id] != nil else { return }
        var restored = directory
        restored.useDefaultName(id)
        try nameStore?.save(restored.chosenNames, remembered: restored.remembered, excluded: exclusions.excluded)
        savedRemembered = restored.remembered
        namesNotSaved = nil
        directory = restored
        refresh()
        sendLabels()
        onChange?()
    }

    struct NamesUnavailable: LocalizedError {
        var errorDescription: String? { "Names are off until they can be loaded." }
    }

    var names: [String: String] {
        guard namesProblem == nil else { return [:] }
        return Dictionary(directory.conversations.map { ($0.handle, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    var rows: [String] { directory.conversations.map(\.id) }

    var hasConnectedConversation: Bool { directory.conversations.contains(where: \.connectorLive) }

    var watchedFolders: [URL] { discoveries.flatMap(\.watchedFolders) }

    var candidates: [AgentCandidate] { discoveries.flatMap { lastExtras[$0.kind.id]?.candidates ?? [] } }

    struct Unconnected: Equatable {
        var agent: String
        var folder: String
        var row: String
        var name: String { "\(agent) in \(folder)" }
    }

    var unconnected: [Unconnected] {
        discoveries.flatMap { discovery in
            (lastExtras[discovery.kind.id]?.candidates ?? []).map {
                Unconnected(agent: discovery.kind.displayName, folder: URL(fileURLWithPath: $0.cwd).lastPathComponent, row: $0.rowId)
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var discoveredSetupsByAgent: [String: [String]] { lastExtras.mapValues(\.setups) }

    var lastSeen: Set<String> {
        var seen: Set<String> = []
        for (agent, sessions) in lastScan {
            let carried = staleAgents.contains(agent) ? Set(sessions.map(\.id)) : lastExtras[agent]?.carried ?? []
            for native in carried { seen.insert(AgentSessionID.make(agent: agent, native: native)) }
        }
        return seen
    }

    func handle(of id: String) -> String? {
        directory.conversations.first { $0.id == id }?.handle
    }

    func kind(of id: String) -> AgentKind? {
        guard let conversation = directory.conversations.first(where: { $0.id == id }) else { return nil }
        return discoveries.first { $0.kind.id == conversation.agent }?.kind
    }

    private func stillRunning(_ remembered: RememberedName) -> Bool {
        discoveries.first { $0.kind.id == remembered.agent }?.stillRunning(remembered) ?? false
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

    func open(
        _ id: String, makingCurrent: Bool = true, stillWanted: @escaping @MainActor @Sendable () -> Bool = { true },
        asking: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async -> AgentFocusResult {
        guard let conversation = directory.conversations.first(where: { $0.id == id }) else { return .none }
        if makingCurrent { makeCurrent(id) }
        return await focus?.focus(
            session: id, pid: conversation.pid, environment: environments[id] ?? [:], stillWanted: stillWanted, asking: asking) ?? .none
    }

    func sessionInFront(asking: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async -> FrontSession? {
        guard let front else { return nil }
        return await front.shown(among: frontCandidates, asking: asking)
    }

    func sessionInFrontWithoutAsking() async -> FrontSession? {
        let candidates = frontCandidates
        guard let glance, !candidates.isEmpty else { return nil }
        return await glance.shown(among: candidates) { _ in }
    }

    var frontCandidates: [AgentFrontCandidate] {
        (directory.conversations + disconnected).map { AgentFrontCandidate(id: $0.id, pid: $0.pid, environment: environments[$0.id] ?? [:]) }
    }

    static let focusTimeout: Duration = .seconds(3)

    func focusInPlace(_ session: String, definition: String, within timeout: Duration = focusTimeout) async -> TerminalSelection {
        guard transport.isLive(session: session), let features = features[session] else { return .notFound }
        let shipped = kind(of: session)?.connectorFeatures ?? []
        guard features.contains("focus"), features.contains("focusDefinitions") else {
            return shipped.contains("focus") && shipped.contains("focusDefinitions") ? .outdated : .unsupported
        }
        let id = makeId()
        let expiresAt = deadline(after: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: .notFound) }
                focusWaiters[id] = continuation
                transport.enqueue(.focus(id: id, expectedSession: session, expiresAt: expiresAt, definition: definition), for: session)
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
        try nameStore?.save(renamed.chosenNames, remembered: renamed.remembered, excluded: exclusions.excluded)
        savedRemembered = renamed.remembered
        namesNotSaved = nil
        directory = renamed
        sendLabels()
        onChange?()
    }

    func isExcluded(_ id: String) -> Bool { exclusions.excludes(id) }

    func waitingPrompt(of id: String) -> AgentPrompt? { waitingPrompts[id] }

    var disconnectedNames: [String: String] {
        guard namesProblem == nil else { return [:] }
        return Dictionary(disconnected.map { ($0.handle, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    func disconnect(_ id: String) {
        guard exclusions.isKnown else { return }
        exclusions.insert(id)
        saveExclusions()
        if current == id { current = nil }
        for message in outbox.withdraw(conversation: id) {
            retries[message.id] = nil
            report(.notSent(handle(of: id), reason: .disconnected), for: message.id, in: id)
        }
        for (request, entry) in requests where entry.message.conversation == id && !entry.timedOut {
            if transport.withdraw(entry.wire) {
                clearHandOff(request)
                settle(request, .notSent(entry.handle, reason: .disconnected))
            }
        }
        stopAwaiting(id)
        nextRequested.remove(id)
        waitingPrompts[id] = nil
        lastUsed[id] = nil
        onSilence?(id)
        transport.enqueue(.quiet(id: makeId(), expectedSession: id), for: id)
        refresh()
        onChange?()
    }

    func reconnect(_ id: String) {
        guard exclusions.isKnown, exclusions.remove(id) else { return }
        saveExclusions()
        transport.enqueue(.admit(id: makeId(), expectedSession: id), for: id)
        refresh()
        onChange?()
        Task { [weak self] in await self?.rescan(rereadingTitles: true) }
    }

    func retrySavingExclusions() {
        saveExclusions()
        onChange?()
    }

    private func saveExclusions() {
        guard let nameStore else { return }
        do {
            try nameStore.save(directory.chosenNames, remembered: directory.remembered, excluded: exclusions.excluded)
            savedRemembered = directory.remembered
            exclusionsNotSaved = nil
        } catch {
            exclusionsNotSaved = error.localizedDescription
            Log.agents.error("disconnected conversations not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    func renameProblem(_ id: String, to name: String) -> AgentHandles.RenameError? {
        directory.renameProblem(id, to: name)
    }

    func reloadNames() {
        guard let nameStore, namesProblem != nil else { return }
        adopt(nameStore.load())
        refresh()
        onChange?()
    }

    private func rememberNames() {
        let remembered = directory.remembered
        guard let nameStore, namesProblem == nil else { return }
        guard remembered != savedRemembered else {
            namesNotSaved = nil
            return
        }
        do {
            try nameStore.save(directory.chosenNames, remembered: remembered, excluded: exclusions.excluded)
            savedRemembered = remembered
            namesNotSaved = nil
        } catch {
            namesNotSaved = error.localizedDescription
            Log.agents.error("conversation names not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func adopt(_ loaded: AgentNameStore.Loaded) {
        switch loaded {
        case .names(let chosen, let remembered, let excluded):
            directory = AgentDirectory(chosen: chosen, remembered: remembered)
            savedRemembered = remembered
            namesProblem = nil
            exclusions.adopt(excluded)
        case .unavailable(let reason):
            namesProblem = reason
            Log.agents.error("conversation names unavailable: \(reason, privacy: .public)")
        }
    }

    static let defaultScanDeadline: Duration = .seconds(3)
    static let defaultDisconnectGrace: Duration = .seconds(5)
    private let disconnectGrace: Duration
    private let scanDeadline: Duration

    func rescan(rereadingTitles: Bool = true) async {
        if let scanTask {
            rescanWanted = true
            rereadWanted = rereadWanted || rereadingTitles
            await scanTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            var rereading = rereadingTitles
            repeat {
                self?.rescanWanted = false
                self?.rereadWanted = false
                await self?.scanOnce(rereadingTitles: rereading)
                rereading = self?.rereadWanted ?? false
            } while self?.rescanWanted == true
            self?.scanTask = nil
        }
        scanTask = task
        await task.value
    }

    private struct Outstanding {
        let task: Task<AgentScan, Never>
        let startedAt: Date
        var result: AgentScan?
        var waiter: FirstAnswer?
    }

    private func scanOnce(rereadingTitles: Bool) async {
        var results: [(String, AgentScan)] = []
        var scannedAt: [String: Date] = [:]
        for discovery in discoveries {
            let agent = discovery.kind.id
            if outstanding[agent] == nil { begin(agent: agent) { await discovery.scan(rereadingTitles: rereadingTitles) } }
            let startedAt = outstanding[agent]?.startedAt ?? now()
            if let result = await bounded(agent: agent) {
                outstanding[agent] = nil
                results.append((agent, result))
                scannedAt[agent] = startedAt
            } else {
                results.append((agent, .unreadable(
                    "\(discovery.kind.displayName)\u{2019}s session list is not answering, so these are the sessions last seen.")))
            }
        }
        guard !stopped else { return }
        for (agent, result) in results {
            switch result {
            case .found(let scanned, let extras):
                lastScan[agent] = scanned
                lastExtras[agent] = extras
                discoveryProblems[agent] = extras.problem
                staleAgents.remove(agent)
            case .unreadable(let why):
                discoveryProblems[agent] = why
                staleAgents.insert(agent)
            }
        }
        refresh(scannedAt: scannedAt)
    }

    private func begin(agent: String, _ scan: @escaping @MainActor () async -> AgentScan) {
        let task = Task { @MainActor in await scan() }
        outstanding[agent] = Outstanding(task: task, startedAt: now())
        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self, self.outstanding[agent]?.task == task else { return }
            self.outstanding[agent]?.result = result
            self.outstanding[agent]?.waiter?.resume(result)
            self.outstanding[agent]?.waiter = nil
        }
    }

    func stop() {
        stopped = true
        scanTask?.cancel()
        scanTask = nil
        placeTracker?.stop()
        onChange = nil
        onFirstConnection = nil
        onNotice = nil
        onForget = nil
        onResult = nil
        onAttention = nil
    }

    private func bounded(agent: String) async -> AgentScan? {
        if let result = outstanding[agent]?.result { return result }
        let deadline = scanDeadline
        return await withCheckedContinuation { (continuation: CheckedContinuation<AgentScan?, Never>) in
            let answer = FirstAnswer(continuation)
            outstanding[agent]?.waiter = answer
            Task {
                try? await Task.sleep(for: deadline)
                answer.resume(nil)
            }
        }
    }

    private final class FirstAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<AgentScan?, Never>?

        init(_ continuation: CheckedContinuation<AgentScan?, Never>) {
            self.continuation = continuation
        }

        func resume(_ result: AgentScan?) {
            let waiting = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            waiting?.resume(returning: result)
        }
    }

    func refresh(nameReportedFor: String? = nil, scannedAt: [String: Date] = [:]) {
        let before = directory.revision
        let problemsBefore = shownProblems
        var entries: [AgentSession] = []
        var shown: [String: String] = [:]
        var nativeNames: [String: String?] = [:]
        for discovery in discoveries {
            let found = lastScan[discovery.kind.id] ?? []
            for entry in found {
                let id = AgentSessionID.make(agent: entry.agent, native: entry.id)
                if nameReportedFor != id, let previous = registryNames[id], previous != entry.explicitName,
                   (connectorNamesAt[id] ?? .distantPast) <= (scannedAt[entry.agent] ?? .distantFuture) {
                    connectorNames[id] = nil
                }
                registryNames[id] = .some(entry.explicitName)
                let native: String?
                if let reported = connectorNames[id], !Self.isGenerated(reported, entry.title) {
                    native = reported
                } else {
                    native = entry.explicitName ?? entry.title.explicitName
                }
                nativeNames[id] = .some(native)
                shown[id] = native ?? entry.title.generatedTitle
            }
            entries += found
        }
        let excluded = Set(entries.map { AgentSessionID.make(agent: $0.agent, native: $0.id) }.filter(exclusions.excludes))
        let live = Set(entries.map { AgentSessionID.make(agent: $0.agent, native: $0.id) }.filter { !excluded.contains($0) && transport.isLive(session: $0) })
        directory.update(
            entries: entries, live: live, titles: shown, nativeNames: nativeNames, running: stillRunning, excluded: excluded,
            places: placeTracker?.places ?? [:],
            unplaced: placeTracker.map { tracker in
                tracker.unchecked(entries.map { AgentSessionID.make(agent: $0.agent, native: $0.id) }).subtracting(tracker.places.keys)
            } ?? [], unreadSince: placeTracker?.failingSince ?? [:])
        let reported = namesNotSaved
        rememberNames()
        if let current, handle(of: current) == nil { self.current = nil }
        lastUsed = lastUsed.filter { handle(of: $0.key) != nil }
        let listed = Set((directory.conversations + directory.disconnected).map(\.id))
        placeTracker?.notice(listed)
        let ended = connectorStateSessions.filter { !listed.contains($0) && !transport.isLive(session: $0) }
        forgetConnectorState(keepingEnvironments: { !ended.contains($0) }) { !ended.contains($0) && !exclusions.excludes($0) }
        installations = installations.filter { !ended.contains($0.key) }
        nextRequested.subtract(ended)
        for session in ended { transport.forget(session: session) }
        sendLabels()
        let idle = Set(directory.conversations.filter { $0.state == .idle }.map(\.id))
        let stale = now().addingTimeInterval(-Self.runningGrace)
        running = running.filter { !idle.contains($0.key) || $0.value > stale }
        releaseHeld()
        reconcileAttention()
        shownProblems = discoveryProblems
        let extrasChanged = lastExtras != shownExtras
        shownExtras = lastExtras
        if directory.revision != before || namesNotSaved != reported || discoveryProblems != problemsBefore || extrasChanged { onChange?() }
    }

    private func reconcileAttention() {
        let tracked = Set(attention.keys).union(awaitingResult.keys)
        for session in Set(attention.keys).union(goneSince.keys).union(awaitedHandles.keys) where awaitingResult[session] == nil {
            goneSince[session] = nil
            report(attention: nil, for: session)
            awaitedHandles[session] = nil
        }
        for session in Array(awaitingResult.keys) {
            let conversation = directory.conversations.first { $0.id == session }
            if let conversation { awaitedHandles[session] = conversation.handle }
            let wanted: AgentAttention?
            if let conversation, conversation.connectorLive {
                goneSince[session] = nil
                wanted = switch conversation.state {
                case .waitingApproval: .approval
                case .waitingQuestion: .question
                case .userDialog: waitingPrompts[session].map { .waiting($0) }
                default: nil
                }
            } else {
                let since = goneSince[session] ?? startGrace(for: session)
                let grace = Double(disconnectGrace.components.seconds) + Double(disconnectGrace.components.attoseconds) / 1e18
                if now().timeIntervalSince(since) >= grace {
                    wanted = .disconnected
                } else {
                    wanted = conversation == nil ? nil : attention[session]
                }
            }
            report(attention: wanted, for: session)
            if conversation == nil, wanted == .disconnected {
                stopAwaiting(session)
                attention[session] = nil
                goneSince[session] = nil
                awaitedHandles[session] = nil
            }
        }
        clearReturned(except: tracked)
    }

    private func clearReturned(except tracked: Set<String>) {
        let live = Set(directory.conversations.filter(\.connectorLive).map(\.id))
        for session in live.subtracting(liveSessions).subtracting(tracked) {
            onAttention?(session, handle(of: session) ?? "", nil, false)
        }
        let firstConnection = liveSessions.isEmpty && !live.isEmpty
        liveSessions = live
        if firstConnection { onFirstConnection?() }
        waitingPrompts = waitingPrompts.filter { live.contains($0.key) }
    }

    private func forgetConnectorState(keepingEnvironments keptEnvironment: ((String) -> Bool)? = nil, keeping kept: (String) -> Bool) {
        features = features.filter { kept($0.key) }
        loadedVersions = loadedVersions.filter { kept($0.key) }
        environments = environments.filter { keptEnvironment?($0.key) ?? kept($0.key) }
        prompts = prompts.filter { kept($0.key) }
        connectorNames = connectorNames.filter { kept($0.key) }
        connectorNamesAt = connectorNamesAt.filter { kept($0.key) }
        labels = labels.filter { kept($0.key) }
    }

    var connectorStateSessions: Set<String> {
        Set(features.keys).union(environments.keys).union(prompts.keys).union(connectorNames.keys)
            .union(connectorNamesAt.keys).union(labels.keys)
    }

    private func startGrace(for session: String) -> Date {
        let started = now()
        goneSince[session] = started
        let grace = disconnectGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            self?.refresh()
        }
        return started
    }

    private func report(attention wanted: AgentAttention?, for session: String) {
        guard attention[session] != wanted else { return }
        attention[session] = wanted
        onAttention?(session, handle(of: session) ?? awaitedHandles[session] ?? "", wanted, requested.contains(session))
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

    func deliver(_ text: String, to id: String, request: String? = nil, images: [String] = []) async -> AgentReceipt {
        if exclusions.excludes(id) { return .notSent(disconnected.first { $0.id == id }?.handle, reason: .disconnected) }
        guard let conversation = directory.conversations.first(where: { $0.id == id }) else {
            return .notSent(nil, reason: .conversationEnded)
        }
        lastUsed[id] = now()
        let message = AgentOutbox.Message(id: request ?? makeId(), conversation: id, text: text, images: images)
        let handle = conversation.handle
        switch outbox.send(message, state: state(of: id)) {
        case .handOff:
            return await withCheckedContinuation { continuation in
                waiters[message.id] = continuation
                handOff(message, handle: handle)
            }
        case .queue(let reason):
            return .queued(handle, waitingOn: reason)
        case .needsReview(let reason):
            return .kept(handle, reason: Self.kept(reason))
        case .disconnected:
            return .notSent(handle, reason: .connectorNotRunning)
        }
    }

    func prepare(for hello: AgentEvent.Hello) {
        guard !exclusions.excludes(hello.session) else { return }
        if hello.resumesAfterGap { outbox.noteConnectionGap(conversation: hello.session) }
        running[hello.session] = hello.knownIdle ? nil : now()
    }

    func retire(installation: String) {
        let retiring = Set(installations.filter { $0.value == installation }.keys)
        guard !retiring.isEmpty else { return }
        let kept = { (session: String) in !retiring.contains(session) }
        awaitingResult = awaitingResult.filter { kept($0.key) }
        awaitedRequests = awaitedRequests.filter { kept($0.key) }
        nextTyped = nextTyped.filter { kept($0.key) }
        requested = requested.filter(kept)
        nextRequested = nextRequested.filter(kept)
        waitingPrompts = waitingPrompts.filter { kept($0.key) }
        forgetConnectorState(keeping: kept)
        installations = installations.filter { kept($0.key) }
        for session in retiring.sorted() { onSilence?(session) }
        for (agent, sessions) in Dictionary(grouping: retiring, by: { AgentSessionID.agent(of: $0) ?? "" }) {
            discoveries.first { $0.kind.id == agent }?.retire(sessions: Set(sessions.map(AgentSessionID.native)))
        }
        Task { [weak self] in await self?.rescan(rereadingTitles: false) }
    }

    func handle(_ event: AgentEvent) {
        guard !stopped, let event = local(event) else { return }
        if let session = event.session, let agent = AgentSessionID.agent(of: session) {
            discoveries.first { $0.kind.id == agent }?.observe(event.renamingSession(AgentSessionID.native))
        }
        if let session = event.session, exclusions.excludes(session) {
            if case .hello(let hello) = event { installations[session] = hello.installation }
            return
        }
        switch event {
        case .hello(let hello):
            for (request, entry) in requests where entry.message.conversation == hello.session {
                trace(request) { $0.reconnects += 1 }
            }
            resume(hello)
            features[hello.session] = Set(hello.features)
            installations[hello.session] = hello.installation
            loadedVersions[hello.session] = hello.version
            environments[hello.session] = hello.environment
            prompts[hello.session] = hello.prompts
            waitingPrompts[hello.session] = hello.waiting
            labels[hello.session] = nil
            if let title = hello.title {
                connectorNames[hello.session] = .some(title.isEmpty ? nil : title)
            } else {
                connectorNames[hello.session] = nil
            }
            connectorNamesAt[hello.session] = now()
            refresh(nameReportedFor: hello.session)
            readPlaces()
            Task { [weak self] in await self?.rescan(rereadingTitles: true) }
        case .title(let session, let text):
            connectorNames[session] = .some(text.isEmpty ? nil : text)
            connectorNamesAt[session] = now()
            refresh(nameReportedFor: session)
            Task { [weak self] in await self?.rescan(rereadingTitles: true) }
        case .waiting(let session, let prompt):
            waitingPrompts[session] = prompt
            Task { [weak self] in await self?.rescan(rereadingTitles: false) }
        case .notify(let session, let turn, let on):
            _ = notify(session: session, turn: turn, on: on)
        case .focused(let request):
            focusWaiters.removeValue(forKey: request)?.resume(returning: .selected)
        case .ack:
            break
        case .submitted(let request, let turn, let report):
            confirm(request, turn: turn, report: report)
        case .checked(let request, let check, let report):
            guard requests[request]?.check == check else { break }
            trace(request) {
                $0.check = .answered(report.state)
                if report.state != .seen { $0.absorb(report) }
            }
            switch report.state {
            case .seen: confirm(request, turn: report.turn, report: report)
            case .refused: refuse(request, reason: report.reason ?? "")
            default:
                leaveUncertain(request, follows: false)
                stopFollowing(request)
            }
        case .refused(let request, let reason) where focusWaiters[request] != nil:
            focusWaiters.removeValue(forKey: request)?.resume(returning: reason == "unknownFocus" ? .outdated : .notFound)
        case .undelivered(let request, _, _) where focusWaiters[request] != nil:
            focusWaiters.removeValue(forKey: request)?.resume(returning: .notFound)
        case .refused(let request, let reason):
            refuse(request, reason: reason)
        case .undelivered(let request, let reason, true):
            doubt(request, askingConnector: reason != AgentCommandQueue.Undeliverable.retired.rawValue
                && reason != AgentCommandQueue.Undeliverable.instanceGone.rawValue)
        case .undelivered(let request, "expired", false):
            clearHandOff(request)
            settle(request, .notSent(requests[request]?.handle, reason: .expired))
            releaseHeld()
        case .undelivered(let request, "connectionGap", false):
            clearHandOff(request)
            settle(request, .kept(requests[request]?.handle ?? "", reason: .connectionGap))
            releaseHeld()
        case .undelivered(let request, _, false):
            clearHandOff(request)
            settle(request, .notSent(requests[request]?.handle, reason: .connectorNotRunning))
            releaseHeld()
        case .typed(let session, let count):
            typedCounts[session, default: 0] += 1
            if let pending = nextTyped[session] {
                if pending.typedAt == nil { nextTyped[session]?.typedAt = now() } else { nextTyped[session] = nil }
            }
            if let count { prompts[session] = count }
            for (id, entry) in requests where entry.message.conversation == session {
                requests[id]?.followsNextTurn = false
                requests[id]?.typedSince = true
            }
            outbox.noteTyped(conversation: session)
            if handle(of: session) != nil { makeCurrent(session) }
        case .turnStarted(let session, let turn):
            if let awaited = awaitingResult[session], awaited != turn { stopAwaiting(session) }
            if nextRequested.remove(session) != nil { waitForReply(turn, of: session, requested: true) }
            if let pending = nextTyped.removeValue(forKey: session), let typedAt = pending.typedAt,
               now().timeIntervalSince(typedAt) <= typedTurnWindow {
                waitForReply(turn, of: session, requested: false)
                awaitedRequests[session] = pending.request
            }
            if let pending = handingOff[session], requests[pending] != nil { requests[pending]?.turnDuringHandOff = .started(turn) }
            if let (request, _) = requests.first(where: { $0.value.message.conversation == session && $0.value.followsNextTurn }) {
                requests[request]?.followsNextTurn = false
                follow(turn, of: session, for: request)
            }
            handingOff[session] = nil
            running[session] = now()
        case .turnComplete(let session, let reason, let answer):
            handingOff[session] = nil
            for (id, entry) in requests where entry.message.conversation == session && entry.turnDuringHandOff != nil {
                requests[id]?.turnDuringHandOff = .ended
            }
            running[session] = nil
            if awaitingResult[session] != nil {
                let wasRequested = requested.contains(session)
                let origin = awaitedRequests[session]
                stopAwaiting(session)
                if reason == "answer" || reason == "complete" {
                    onResult?(session, handle(of: session) ?? "", answer, wasRequested, origin)
                } else if let body = SpokenResult.ending(reason) {
                    onEnded?(session, handle(of: session) ?? "", body, wasRequested, origin)
                }
            }
            if reason == "aborted" { outbox.noteInterrupted(conversation: session) }
            refresh()
            Task { [weak self] in await self?.rescan(rereadingTitles: false) }
        }
        reconcileAttention()
    }

    var readAloud: Set<String> { requested }
    var readNextAloud: Set<String> { nextRequested }

    func notify(session: String, turn: String, on: Bool) -> Bool {
        guard !stopped, !exclusions.excludes(session) else { return false }
        guard on else {
            cancelReadAloud(session)
            return speaks()
        }
        guard speaks() else { return false }
        let wasRequested = requested.contains(session)
        if turn.isEmpty {
            nextRequested.insert(session)
        } else {
            waitForReply(turn, of: session, requested: true)
        }
        if !wasRequested, requested.contains(session), let current = attention[session] {
            onAttention?(session, handle(of: session) ?? awaitedHandles[session] ?? "", current, true)
        }
        reconcileAttention()
        onChange?()
        return true
    }

    func cancelReadAloud(_ id: String) {
        nextRequested.remove(id)
        stopAwaiting(id)
        onWithdraw?(id)
        reconcileAttention()
        onChange?()
    }

    func speechTurnedOff() {
        guard !requested.isEmpty || !nextRequested.isEmpty else { return }
        for session in requested { stopAwaiting(session) }
        nextRequested = []
        reconcileAttention()
        onChange?()
    }

    private func waitForReply(_ turn: String, of session: String, requested isRequested: Bool) {
        if awaitingResult[session] != turn { stopAwaiting(session) }
        awaitingResult[session] = turn
        if isRequested { requested.insert(session) }
    }

    func awaitTypedTurn(of session: String, request: String) {
        nextTyped[session] = TypedTurn(request: request)
    }

    func forgetTypedTurn(of session: String, request: String) {
        if nextTyped[session]?.request == request { nextTyped[session] = nil }
    }

    private func stopAwaiting(_ session: String) {
        awaitingResult[session] = nil
        awaitedRequests[session] = nil
        if requested.remove(session) != nil { onChange?() }
    }

    private func resume(_ hello: AgentEvent.Hello) {
        let session = hello.session
        let running = hello.reportsTurn ? hello.turn ?? "" : ""
        if let awaited = awaitingResult[session], awaited != running {
            let wasRequested = requested.contains(session)
            let origin = awaitedRequests[session]
            stopAwaiting(session)
            if hello.reportsTurn, running.isEmpty, hello.knownIdle {
                onEnded?(session, handle(of: session) ?? "", SpokenResult.repliedBody, wasRequested, origin)
            }
        }
        guard nextRequested.contains(session) else { return }
        if !running.isEmpty {
            nextRequested.remove(session)
            waitForReply(running, of: session, requested: true)
        } else if !hello.reportsTurn || !hello.knownIdle {
            nextRequested.remove(session)
            onChange?()
        }
    }

    private func state(of id: String) -> AgentLiveState? {
        guard let conversation = directory.conversations.first(where: { $0.id == id }), conversation.connectorLive else { return nil }
        if handingOff[id] != nil || running[id] != nil { return .working }
        return conversation.state
    }

    func delivery(of request: String) -> AgentDelivery? { traced[request]?.delivery }

    func deliveryFact(of request: String) -> HistoryEntry.Fact? {
        traced[request].map { AgentHistoryFacts.delivery($0.delivery, agent: agentName(of: $0.conversation)) }
    }

    private func agentName(of conversation: String) -> String {
        let agent = AgentSessionID.agent(of: conversation)
        return discoveries.first { $0.kind.id == agent }?.kind.displayName ?? "the agent"
    }

    private func trace(_ request: String, _ change: (inout AgentDelivery) -> Void) {
        guard var entry = traced[request] else { return }
        change(&entry.delivery)
        guard entry.delivery != traced[request]?.delivery else { return }
        traced[request] = entry
        guard waiters[request] == nil, let fact = deliveryFact(of: request) else { return }
        onDelivery?(request, fact)
    }

    private func startTrace(_ request: String, in conversation: String) {
        if traced[request] == nil {
            tracedOrder.append(request)
            if tracedOrder.count > Self.keptDeliveries { traced[tracedOrder.removeFirst()] = nil }
        }
        traced[request] = Traced(conversation: conversation, delivery: AgentDelivery(handedOff: now()))
    }

    private func confirm(_ request: String, turn: String, report: AgentDeliveryReport) {
        let late = requests[request]?.timedOut == true
        trace(request) {
            $0.absorb(report)
            if $0.confirmed == nil { $0.confirmed = now() }
        }
        if late, let fact = deliveryFact(of: request) {
            Log.agents.notice("delivery confirmed late: \(fact.value, privacy: .public)")
        }
        if let conversation = requests[request]?.message.conversation, !turn.isEmpty, awaitingResult[conversation] != turn {
            stopAwaiting(conversation)
            awaitingResult[conversation] = turn
            awaitedRequests[conversation] = request
        }
        settle(request, .sent(requests[request]?.handle ?? ""))
    }

    private func follow(_ turn: String, of conversation: String, for request: String) {
        guard awaitingResult[conversation] == nil else { return }
        waitForReply(turn, of: conversation, requested: false)
        awaitedRequests[conversation] = request
        trace(request) { $0.followedTurn = now() }
    }

    private func doubt(_ request: String, askingConnector: Bool = true) {
        guard let entry = requests[request], !entry.timedOut, entry.check == nil else { return }
        let conversation = entry.message.conversation
        guard askingConnector, features[conversation]?.contains("check") == true else { return leaveUncertain(request, follows: true) }
        let check = "check-\(request)-\(entry.attempt)"
        requests[request]?.check = check
        trace(request) { $0.check = .asked }
        transport.enqueue(.check(id: check, expectedSession: conversation, request: entry.wire, expiresAt: deadline(after: checkWait)), for: conversation)
        let wait = checkWait
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.checkUnanswered(request, check: check)
        }
    }

    private func checkUnanswered(_ request: String, check: String) {
        guard let entry = requests[request], entry.check == check, !entry.timedOut else { return }
        trace(request) { $0.check = .unanswered }
        leaveUncertain(request, follows: true)
    }

    private func refuse(_ request: String, reason: String) {
        clearHandOff(request)
        guard let entry = requests[request] else { return releaseHeld() }
        stopFollowing(request)
        let handle = entry.handle
        switch reason {
        case "working" where !entry.timedOut:
            requests[request] = nil
            retries[request] = entry.retry + 1
            running[entry.message.conversation] = now()
            _ = outbox.send(entry.message, state: .working)
            report(.queued(handle), for: request, in: entry.message.conversation)
            return
        case "typedSince": settle(request, .kept(handle, reason: .typedSince))
        case "draft": settle(request, .kept(handle, reason: .composing))
        case "filled": settle(request, Self.filled(handle: handle, features: features[entry.message.conversation]))
        case "dialog": settle(request, .kept(handle, reason: .dialog))
        default: settle(request, .notSent(handle, reason: Self.notSent(reason)))
        }
        releaseHeld()
    }

    private func handOff(_ message: AgentOutbox.Message, handle: String) {
        attempts += 1
        let attempt = attempts
        let entry = Request(message: message, handle: handle, attempt: attempt, retry: retries.removeValue(forKey: message.id) ?? 0)
        requests[message.id] = entry
        startTrace(message.id, in: message.conversation)
        handingOff[message.conversation] = message.id
        transport.enqueue(
            .submit(
                id: entry.wire, expectedSession: message.conversation, text: message.text,
                expectedPrompts: prompts[message.conversation], expiresAt: deadline(after: receiptTimeout),
                images: takesImages(message.conversation) ? message.images : []),
            for: message.conversation)
        let timeout = receiptTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard self?.requests[message.id]?.attempt == attempt else { return }
            self?.doubt(message.id)
        }
    }

    private func leaveUncertain(_ request: String, follows: Bool) {
        guard let entry = requests[request], !entry.timedOut else { return }
        requests[request]?.timedOut = true
        trace(request) { $0.doubted = now() }
        if let fact = deliveryFact(of: request) { Log.agents.notice("delivery not confirmed: \(fact.value, privacy: .public)") }
        report(.uncertain(entry.handle), for: request, in: entry.message.conversation)
        let conversation = entry.message.conversation
        let follows = follows && !entry.typedSince
        switch entry.turnDuringHandOff {
        case .started(let turn)? where follows: follow(turn, of: conversation, for: request)
        case nil where follows: requests[request]?.followsNextTurn = true
        default: break
        }
        let limit = handOffLimit
        Task { [weak self] in
            try? await Task.sleep(for: limit)
            self?.releaseHandOff(request)
        }
    }

    private func releaseHandOff(_ request: String) {
        guard let entry = requests.removeValue(forKey: request) else { return }
        if handingOff[entry.message.conversation] == request { handingOff[entry.message.conversation] = nil }
        onForget?(request)
        releaseHeld()
    }

    private func deadline(after duration: Duration) -> Date {
        now().addingTimeInterval(TimeInterval(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    private func stopFollowing(_ request: String) {
        guard let entry = requests[request] else { return }
        requests[request]?.followsNextTurn = false
        let conversation = entry.message.conversation
        guard awaitedRequests[conversation] == request else { return }
        trace(request) { $0.followedTurn = nil }
        if requested.contains(conversation) { awaitedRequests[conversation] = nil } else { stopAwaiting(conversation) }
    }

    private func local(_ event: AgentEvent) -> AgentEvent? {
        func request(_ wire: String) -> String? {
            if let match = requests.first(where: { $0.value.wire == wire }) { return match.key }
            return requests[wire] == nil ? wire : nil
        }
        switch event {
        case .submitted(let wire, let turn, let report):
            return request(wire).map { .submitted(request: $0, turn: turn, report: report) }
        case .checked(let wire, let check, let report):
            return request(wire).map { .checked(request: $0, check: check, report: report) }
        case .refused(let wire, let reason):
            return request(wire).map { .refused(request: $0, reason: reason) }
        case .undelivered(let wire, let reason, let handedOff):
            return request(wire).map { .undelivered(request: $0, reason: reason, handedOff: handedOff) }
        default:
            return event
        }
    }

    private func clearHandOff(_ request: String) {
        guard let conversation = requests[request]?.message.conversation, handingOff[conversation] == request else { return }
        handingOff[conversation] = nil
    }

    private func settle(_ request: String, _ receipt: AgentReceipt) {
        guard let entry = requests.removeValue(forKey: request) else { return }
        report(receipt, for: request, in: entry.message.conversation)
    }

    private func report(_ receipt: AgentReceipt, for request: String, in conversation: String) {
        if let waiter = waiters.removeValue(forKey: request) {
            waiter.resume(returning: receipt)
        } else {
            onNotice?(receipt, request, conversation)
        }
    }

    private func releaseHeld() {
        for release in outbox.release(state: state(of:)) {
            let handle = handle(of: release.message.conversation)
            switch release.decision {
            case .handOff:
                handOff(release.message, handle: handle ?? "")
            case .needsReview(let reason):
                retries[release.message.id] = nil
                report(.kept(handle ?? "", reason: Self.kept(reason)), for: release.message.id, in: release.message.conversation)
            case .disconnected:
                retries[release.message.id] = nil
                report(.notSent(handle, reason: .connectorNotRunning), for: release.message.id, in: release.message.conversation)
            case .queue:
                break
            }
        }
    }

    private static func kept(_ reason: AgentDeliveryDecision.ReviewReason) -> AgentReceipt.KeptReason {
        switch reason {
        case .typedSince: .typedSince
        case .interrupted: .interrupted
        case .connectionGap: .connectionGap
        }
    }

    func typedCount(_ session: String) -> Int { typedCounts[session] ?? 0 }

    func takesImages(_ session: String) -> Bool { features[session]?.contains("images") == true }

    static func filled(handle: String, features: Set<String>?) -> AgentReceipt {
        features?.contains("fill") == true ? .kept(handle, reason: .inPromptBox) : .notSent(handle, reason: .stopped)
    }

    private static func notSent(_ reason: String) -> AgentReceipt.NotSentReason {
        if reason == "sessionChanged" { return .conversationChanged }
        if reason == "stopped" { return .stopped }
        if reason == "expired" { return .expired }
        if reason == "disconnected" { return .disconnected }
        return .refused(reason)
    }
}

@MainActor
final class AgentRuntime {
    private final class HubBox: @unchecked Sendable { weak var hub: AgentHub? }

    let hub: AgentHub
    private let server: AgentBridgeServer
    private var pace: Task<Void, Never>?
    private var watcher: FolderWatcher?
    private var quick = false
    private var stopped = false
    var settingsOpen = false {
        didSet { if settingsOpen && !oldValue { wake() } }
    }

    static func rescanInterval(connected: Bool, settingsOpen: Bool) -> Duration {
        connected || settingsOpen ? .seconds(1) : .seconds(10)
    }

    static func places(surfaces: ResolvedSurfaces, sources: [any AgentPlaceReading]) -> CombinedPlaceReader {
        CombinedPlaceReader(readers: sources + [TerminalPlaceReader(surfaces: surfaces)])
    }

    static func bridgeDirectory(supportDir: URL) -> URL {
        supportDir.appendingPathComponent("agents", isDirectory: true)
    }

    init(
        supportDir: URL, surfaces: ResolvedSurfaces, placeSources: [any AgentPlaceReading], discovery: [any AgentDiscovery],
        setups: ConnectorSetupRegistry, legacyAgent: String
    ) throws {
        let directory = Self.bridgeDirectory(supportDir: supportDir)
        let token = try AgentBridgeToken.loadOrCreate(in: directory)
        let box = HubBox()
        let exclusions = AgentExclusions(nil)
        server = AgentBridgeServer(
            directory: directory, token: token,
            admits: { setups.admits(agent: $0, installation: $1) },
            excludes: { exclusions.excludes($0) },
            onHello: { hello, done in
                Task { @MainActor in
                    box.hub?.prepare(for: hello)
                    done()
                }
            },
            onNotify: { event, answer in
                Task { @MainActor in
                    guard case .notify(let session, let turn, let on) = event else { return answer(false) }
                    answer(box.hub?.notify(session: session, turn: turn, on: on) ?? false)
                }
            }
        ) { event in
            Task { @MainActor in box.hub?.handle(event) }
        }
        hub = AgentHub(
            transport: server, discovery: discovery,
            names: AgentNameStore(directory: directory, legacyAgent: legacyAgent),
            focus: AgentTerminalFocus(
                plan: AgentTerminalFocus.plan(surfaces), connector: { session, definition in await box.hub?.focusInPlace(session, definition: definition) ?? .notFound }),
            front: AgentFront(surfaces: surfaces), glance: AgentFront.confirmingWithoutAsking(surfaces), exclusions: exclusions,
            places: Self.places(surfaces: surfaces, sources: placeSources))
        box.hub = hub
        try server.start()
        hub.onFirstConnection = { [weak self] in
            guard self?.quick == false else { return }
            self?.wake()
        }
        Task { @MainActor [weak self] in
            await self?.hub.rescan()
            self?.wake()
        }
    }

    private func wake() {
        guard !stopped else { return }
        pace?.cancel()
        pace = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.step() else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func step() async -> Duration {
        hub.tickPlaces(settingsOpen: settingsOpen)
        await hub.rescan(rereadingTitles: false)
        watch(hub.watchedFolders)
        let interval = Self.rescanInterval(connected: hub.hasConnectedConversation, settingsOpen: settingsOpen)
        quick = interval == Self.rescanInterval(connected: true, settingsOpen: false)
        return interval
    }

    private func watch(_ folders: [URL]) {
        guard folders != watcher?.folders ?? [] else { return }
        watcher = FolderWatcher(folders: folders) { [weak hub] in
            Task { @MainActor in await hub?.rescan(rereadingTitles: false) }
        }
    }

    func retire(installation: String) {
        server.retire(installation: installation)
        hub.retire(installation: installation)
    }

    func stop() {
        stopped = true
        pace?.cancel()
        pace = nil
        watcher = nil
        hub.stop()
        server.stop()
    }
}
