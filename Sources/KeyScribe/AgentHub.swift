import Foundation
import KeyScribeKit

protocol AgentTransport: AnyObject {
    func enqueue(_ command: AgentCommand, for session: String)
    func isLive(session: String) -> Bool
    func withdraw(_ id: String) -> Bool
    func forget(session: String)
    func rehello(session: String)
    func silence(agents: Set<String>)
}

extension AgentBridgeServer: AgentTransport {
    func enqueue(_ command: AgentCommand, for session: String) {
        enqueue(command, for: session, instance: nil)
    }
}

enum AgentReceipt: Equatable {
    enum PromptBoxCause: Equatable { case afterStop, awaitingReturn, besideText, joinedDraft, joinedDraftMidTurn }
    enum KeptReason: Equatable {
        case composing, typedSince, interrupted, connectionGap, dialog, inPromptBox(PromptBoxCause), declined(by: String, saying: String, besideText: Bool)
    }
    enum NotSentReason: Equatable {
        case conversationEnded, connectorNotRunning, conversationChanged, stopped, expired, disconnected, refused(String), hostTakesNoMessages(String)
        case newConversationNotInFront(String), couldNotStart(String)
    }

    case sent(String)
    case sentWithDraft(String)
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
        var box = false
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
    var onLeftInPromptBox: ((_ request: String, _ conversation: String, _ handle: String) -> Void)?
    var onChange: (() -> Void)?
    var onFirstConnection: (() -> Void)?
    var onResult: ((_ conversation: String, _ handle: String, _ answer: String, _ requested: Bool, _ origin: String?, _ cause: SpokenResult.Cause?) -> Void)?
    var onEnded: ((_ conversation: String, _ handle: String, _ body: String, _ requested: Bool, _ origin: String?) -> Void)?
    var onAttention: ((_ conversation: String, _ handle: String, _ attention: AgentAttention?, _ requested: Bool) -> Void)?
    var onWithdraw: ((_ conversation: String) -> Void)?
    var onDelivery: ((_ request: String, _ fact: HistoryEntry.Fact) -> Void)?
    private var traced: [String: Traced] = [:]
    private var tracedOrder: [String] = []
    private var asked: [String: String] = [:]
    private var askedOrder: [String] = []
    private var attempts = 0
    private var retries: [String: Int] = [:]
    var speaks: () -> Bool = { false }
    var bundledVersion: (_ agent: String) -> String? = { _ in nil }
    private var awaitingResult: [String: String] = [:]
    private var awaitedRequests: [String: String] = [:]
    private var nextTyped: [String: TypedTurn] = [:]
    private var filed: [String: Filing] = [:]
    private var inHosts: [String: String] = [:]
    private var rehelloAsked: Set<String> = []
    private var expected: Set<String> = []
    private var carriedNames: [String: String] = [:]
    private var processIdentities: [String: ProcessIdentity] = [:]
    private var hostFollows: [String: [HostFollow]] = [:]
    private var delivering: [String: String] = [:]
    private var linked: [String: String] = [:]
    private var matched: Set<String> = []
    private var heldResults: [String: () -> Void] = [:]
    private var uncertainHosted: [String: (handle: String, conversation: String, withDraft: Bool)] = [:]
    private struct TypedTurn {
        var request: String
        var typedAt: Date?
        var prompt: String?
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
    private let hosts: [HostDiscovery]
    private let hostDeadline: Duration
    private let processEnvironment: (_ pid: Int, _ keys: Set<String>) -> [String: String]
    private let processParent: (_ pid: Int) -> Int?
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
    private var absorbed: [String: (turn: String, prompt: String)] = [:]
    private struct Steered {
        let wire: String
        let request: String
        let handle: String
        let conversation: String
    }

    private var steered: [Steered] = []
    private var leftInBox: [String: [Steered]] = [:]
    private var filledWires: [String: String] = [:] {
        didSet { if filledWires.count > Self.keptDeliveries { filledWires.remove(at: filledWires.startIndex) } }
    }
    private var promptBoxChecks: [String: CheckedContinuation<Bool, Never>] = [:]
    private enum HostJoin { case sent, empty, kept(AgentReceipt.KeptReason), unknown }
    private var hostJoins: [String: CheckedContinuation<HostJoin, Never>] = [:]
    private enum HostStart { case sent(withDraft: Bool), refused(String, detail: String?), unknown }
    private var hostStarts: [String: CheckedContinuation<HostStart, Never>] = [:]
    private var startFollows: [String: [HostFollow]] = [:]
    private var newConversationShown: [String: String] = [:]
    private var hostOwned: Set<String> = []
    var promptBoxCheckWait: Duration = .seconds(1)
    private var connectorNames: [String: String?] = [:]
    private var registryNames: [String: String?] = [:]
    private var labels: [String: String] = [:]
    private var handingOff: [String: String] = [:]
    private var running: [String: Date] = [:]
    private var turns: [String: String] = [:]
    private var lastUsed: [String: Date] = [:]
    private var shownByHost: [String: String] = [:]
    private var shownWithDraft: [String: String] = [:]

    init(
        transport: AgentTransport, discovery: [any AgentDiscovery], names: AgentNameStore? = nil,
        focus: AgentTerminalFocusing? = nil, front: AgentFronting? = nil, glance: AgentFronting? = nil,
        receiptTimeout: Duration = .seconds(8), handOffLimit: Duration = .seconds(30), checkWait: Duration = AgentHub.defaultCheckWait,
        disconnectGrace: Duration = AgentHub.defaultDisconnectGrace, scanDeadline: Duration = AgentHub.defaultScanDeadline, exclusions: AgentExclusions = AgentExclusions(nil),
        places: (any AgentPlaceReading)? = nil, hosts: [AgentHostIntegration] = [],
        hostAllowed: @escaping @MainActor (String) -> Bool = { _ in false },
        hostDeadline: Duration = AgentHub.defaultHostDeadline,
        processEnvironment: @escaping (_ pid: Int, _ keys: Set<String>) -> [String: String] = { _, _ in [:] },
        processParent: @escaping (_ pid: Int) -> Int? = { _ in nil },
        now: @escaping () -> Date = Date.init, makeId: @escaping () -> String = { UUID().uuidString }
    ) {
        self.processEnvironment = processEnvironment
        self.processParent = processParent
        self.hosts = hosts.map { host in HostDiscovery(host, allowed: { hostAllowed(host.kind.id) }, now: now) }
        self.hostDeadline = hostDeadline
        self.exclusions = exclusions
        self.transport = transport
        self.disconnectGrace = disconnectGrace
        self.scanDeadline = scanDeadline
        nameStore = names
        self.focus = focus
        self.front = front
        self.glance = glance
        discoveries = discovery + self.hosts
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
        silenceHostsTurnedOff()
    }

    private(set) var placeTracker: AgentPlaceTracker?
    private var silencedHosts: Set<String>?

    private func silenceHostsTurnedOff() {
        let off = Set(hosts.filter { !$0.isEnabled }.map(\.kind.id))
        guard off != silencedHosts else { return }
        silencedHosts = off
        transport.silence(agents: off)
    }

    private static func newestOfEach(_ entries: [AgentSession]) -> [AgentSession] {
        var kept: [String: Int] = [:]
        var result: [AgentSession] = []
        for entry in entries {
            guard let index = kept[entry.id] else {
                kept[entry.id] = result.count
                result.append(entry)
                continue
            }
            if (entry.startedAt ?? .min) > (result[index].startedAt ?? .min) { result[index] = entry }
        }
        return result
    }

    private static func isGenerated(_ reported: String?, _ title: AgentTitle) -> Bool {
        guard let reported, let generated = title.generatedTitle, title.explicitName == nil else { return false }
        return AgentHandles.matchKey(reported) == AgentHandles.matchKey(generated)
    }

    private var placeQueries: [AgentPlaceQuery] {
        (directory.conversations + directory.disconnected).compactMap { conversation in
            guard let pid = conversation.pid else { return nil }
            return AgentSessionID.split(conversation.id).map {
                AgentPlaceQuery(
                    id: conversation.id, agent: $0.agent, native: $0.native, pid: pid,
                    environment: environments[conversation.id] ?? [:], placed: placeTracker?.places[conversation.id] != nil)
            }
        }
    }

    func placesUnread(_ ids: [String]) -> Bool {
        let readable = Set(placeQueries.map(\.id))
        return placeTracker.map { !$0.unattempted(ids.filter(readable.contains)).isEmpty } ?? false
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

    var agentNames: [String: String] {
        Dictionary(discoveries.map { ($0.kind.id, $0.kind.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    func kind(of id: String) -> AgentKind? {
        guard let conversation = directory.conversations.first(where: { $0.id == id }) else { return nil }
        return discoveries.first { $0.kind.id == conversation.runningAgent }?.kind
    }

    private func stillRunning(_ remembered: RememberedName) -> Bool {
        discoveries.first { $0.kind.id == remembered.agent }?.stillRunning(remembered) ?? false
    }

    var recordingOrder: [AgentConversation] {
        AgentRoster.recordingOrder(directory.conversations, lastUsed: lastUsed)
    }

    func noteUsed(_ id: String) {
        lastUsed[id] = now()
    }

    func open(
        _ id: String, stillWanted: @escaping @MainActor @Sendable () -> Bool = { true },
        asking: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async -> AgentFocusResult {
        guard let conversation = directory.conversations.first(where: { $0.id == id }) else { return .none }
        if let (source, location) = host(of: conversation) {
            guard stillWanted() else { return .none }
            switch await Self.within(hostDeadline, otherwise: AgentHostOpen.failed, { await source.host.open(location, stillWanted: stillWanted) }) {
            case .opened: return .exact
            case .requested: return .requested(source.kind.displayName)
            case .failed, .unsupported: break
            }
        }
        guard let pid = conversation.pid else { return .none }
        return await focus?.focus(
            session: id, pid: pid, environment: environments[id] ?? [:], stillWanted: stillWanted, asking: asking) ?? .none
    }

    func sessionInFront(asking: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async -> FrontSession? {
        if let front, let shown = await front.shown(among: frontCandidates, asking: asking) { return shown }
        return await hostInFront()
    }

    func sessionInFrontWithoutAsking() async -> FrontSession? {
        let candidates = frontCandidates
        if let glance, !candidates.isEmpty, let shown = await glance.shown(among: candidates, asking: { _ in }) { return shown }
        return await hostInFront()
    }

    static func newConversation(in host: String) -> String {
        AgentSessionID.make(agent: host, native: newConversationNative)
    }

    private static let newConversationNative = "new conversation"

    private static func carriesNewConversations(_ session: String) -> Bool {
        AgentSessionID.native(session).hasPrefix(newConversationNative + "@")
    }

    private static func instance(of session: String) -> String? {
        let key = AgentSessionID.native(session)
        return key.firstIndex(of: "@").map { String(key[key.index(after: $0)...]) }
    }

    enum UnheardHost: Equatable {
        case missing(String)
        case notConnected(String)
    }

    func hostCopyUnheardInFront() -> UnheardHost? {
        for source in hosts {
            guard let copy = source.host.copyInFront() else { continue }
            guard copy.enrolled else { return .missing(copy.name) }
            let carrier = AgentSessionID.make(
                agent: source.kind.id,
                native: AgentHostLocation(host: source.kind.id, instance: copy.instance, native: Self.newConversationNative).conversationKey)
            let heard = transport.isLive(session: carrier) || directory.conversations.contains {
                $0.connectorLive && $0.host?.host == source.kind.id && $0.host?.instance == copy.instance
            }
            return heard ? nil : .notConnected(copy.name)
        }
        return nil
    }

    private func startingHost(_ id: String) -> HostDiscovery? {
        guard let (agent, native) = AgentSessionID.split(id), native == Self.newConversationNative else { return nil }
        return hosts.first { $0.kind.id == agent }
    }

    func newConversationName(_ id: String) -> String? {
        startingHost(id).map { Self.newConversationName(of: $0.kind) }
    }

    private static func newConversationName(of kind: AgentKind) -> String {
        "a new \(kind.displayName) conversation"
    }

    private static func slot(_ host: String, _ instance: String?) -> String { host + "\n" + (instance ?? "") }

    private func shown(in slots: [String: String], host: String, instance: String?) -> String? {
        instance.flatMap { slots[Self.slot(host, $0)] }
    }

    private func shown(in slots: [String: String], by source: HostDiscovery, instance: String?) -> String? {
        let mine = slots.filter { $0.key.hasPrefix(Self.slot(source.kind.id, nil)) }
        guard mine.count > 1 else { return mine.first?.value }
        return shown(in: slots, host: source.kind.id, instance: instance)
    }

    private func startCarrier(_ source: HostDiscovery, instance: String?) -> String? {
        guard source.isEnabled, let carrier = shown(in: newConversationShown, host: source.kind.id, instance: instance),
              transport.isLive(session: carrier),
              features[carrier]?.contains("start") == true, !exclusions.excludes(carrier)
        else { return nil }
        return carrier
    }

    func newConversationInFront() async -> FrontSession? {
        for source in hosts {
            guard let app = source.host.focusedWindow(), startCarrier(source, instance: app.instance) != nil else { continue }
            return FrontSession(id: Self.newConversation(in: source.kind.id), app: FrontApp(bundle: app.bundle, pid: app.pid, name: app.name, window: app.window))
        }
        return nil
    }

    private func start(_ text: String, through source: HostDiscovery, request: String, inFront: Bool) async -> AgentReceipt {
        let host = source.kind.id
        remember(asked: text, for: request)
        let name = Self.newConversationName(of: source.kind)
        let notInFront = AgentReceipt.notSent(nil, reason: .newConversationNotInFront(source.kind.displayName))
        guard inFront, let carrier = startCarrier(source, instance: source.host.focusedWindow()?.instance) else { return notInFront }
        let known = Set((directory.conversations + disconnected).filter { $0.host?.host == host }.map(\.id))
        let at = now()
        let copy = Self.slot(host, Self.instance(of: carrier))
        var follows = startFollows[copy, default: []] + [HostFollow(
            prompt: AgentPromptDigest.of(text), request: request, expires: at.addingTimeInterval(Self.hostTurnWait), known: known)]
        let dropped = follows.enumerated().filter { index, follow in
            (follow.expires ?? .distantFuture) <= at || index < follows.count - Self.hostFollowLimit
        }.map(\.element.request)
        follows.removeAll { dropped.contains($0.request) }
        for old in dropped { uncertainHosted[old] = nil }
        startFollows[copy] = follows
        let wire = makeId()
        let wait = receiptTimeout
        transport.enqueue(.start(id: wire, expectedSession: carrier, text: text, expiresAt: deadline(after: wait)), for: carrier)
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.hostStarts.removeValue(forKey: wire)?.resume(returning: .unknown)
        }
        let answer = await withCheckedContinuation { hostStarts[wire] = $0 }
        switch answer {
        case .sent(let withDraft):
            return withDraft ? .sentWithDraft(name) : .sent(name)
        case .unknown:
            uncertainHosted[request] = (name, Self.newConversation(in: host), false)
            return .uncertain(name)
        case .refused(let reason, let detail):
            startFollows[copy]?.removeAll { $0.request == request }
            if let detail { return .kept(name, reason: .declined(by: source.kind.displayName, saying: detail, besideText: reason == "added")) }
            switch reason {
            case "draft": return .kept(name, reason: .composing)
            case "added": return .kept(name, reason: .inPromptBox(.besideText))
            case "filled": return .kept(name, reason: .inPromptBox(.awaitingReturn))
            case "gone": return notInFront
            default: return .notSent(nil, reason: .couldNotStart(source.kind.displayName))
            }
        }
    }

    private func hostInFront() async -> FrontSession? {
        for source in hosts where source.isEnabled {
            if let shown = await inFront(of: source) { return shown }
        }
        return nil
    }

    func hostShows(_ id: String) async -> Bool? {
        guard let hosted = (directory.conversations + disconnected).first(where: { $0.id == id })?.host?.host else { return nil }
        guard let source = hosts.first(where: { $0.kind.id == hosted }), source.isEnabled else { return false }
        return await inFront(of: source)?.id == id
    }

    private func inFront(of source: HostDiscovery) async -> FrontSession? {
        let mine = (directory.conversations + disconnected).filter { $0.host?.host == source.kind.id }
        guard !mine.isEmpty else { return nil }
        let locations = mine.compactMap(\.host)
        let app = source.host.focusedWindow()
        let reported = shown(in: shownByHost, by: source, instance: app?.instance)
            .flatMap { id in transport.isLive(session: id) ? mine.first { $0.id == id }?.host : nil }
        guard case .shown(let location, let app) = await Self.within(
            hostDeadline, otherwise: AgentHostFront.unknown, { await source.host.front(among: locations, reported: reported, in: app) }),
              let shown = mine.first(where: { $0.host == location })
        else { return nil }
        return FrontSession(id: shown.id, app: FrontApp(bundle: app.bundle, pid: app.pid, name: app.name, window: app.window))
    }

    var frontCandidates: [AgentFrontCandidate] {
        (directory.conversations + disconnected).compactMap { conversation in
            conversation.pid.map { AgentFrontCandidate(id: conversation.id, pid: $0, environment: environments[conversation.id] ?? [:]) }
        }
    }

    static let focusTimeout: Duration = .seconds(3)

    func focusInPlace(_ session: String, definition: String, within timeout: Duration = focusTimeout) async -> TerminalSelection {
        guard transport.isLive(session: session), let features = features[session] else { return .notFound }
        guard features.contains("focus"), features.contains("focusDefinitions") else {
            return directory.conversations.first(where: { $0.id == session }).map(runsOlderConnector) == true ? .outdated : .unsupported
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

    func runsOlderConnector(_ conversation: AgentConversation) -> Bool {
        guard features[conversation.id] != nil, !hostOwned.contains(conversation.id), let bundled = bundledVersion(conversation.runningAgent)
        else { return false }
        return loadedVersions[conversation.id] != bundled
    }

    var olderConnectors: Set<String> { Set(directory.conversations.filter(runsOlderConnector).map(\.id)) }

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
        if let conversation = directory.conversations.first(where: { $0.id == id }), let (source, location) = host(of: conversation) {
            let name = conversation.handle
            Task { [weak self] in
                guard await source.host.rename(location, to: name) else { return }
                source.expect()
                await self?.rescan(rereadingTitles: false)
            }
        }
    }

    func isExcluded(_ id: String) -> Bool { exclusions.excludes(id) }

    var openPrompts: [String: AgentPrompt] { waitingPrompts }

    var disconnectedNames: [String: String] {
        guard namesProblem == nil else { return [:] }
        return Dictionary(disconnected.map { ($0.handle, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    func disconnect(_ id: String) {
        guard exclusions.isKnown else { return }
        exclusions.insert(id)
        if let other = counterpart(of: id) { exclusions.insert(other) }
        for (request, conversation) in delivering where conversation == id { stopFollowingHosted(request, in: id) }
        hostFollows[id] = nil
        shownByHost = shownByHost.filter { $0.value != id && $0.value != counterpart(of: id) }
        shownWithDraft = shownWithDraft.filter { $0.value != id && $0.value != counterpart(of: id) }
        newConversationShown = newConversationShown.filter { $0.value != id && $0.value != counterpart(of: id) }
        saveExclusions()
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
        if let other = counterpart(of: id) { _ = exclusions.remove(other) }
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
        case .names(let names, let remembered, let excluded):
            directory = AgentDirectory(chosen: names, remembered: remembered)
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

    func refreshHostsForPress() async {
        guard hosts.contains(where: \.isEnabled) else { return }
        await rescan(rereadingTitles: false, wantingHosts: true)
    }

    func rescan(rereadingTitles: Bool = true, wantingHosts: Bool = false) async {
        if wantingHosts { hosts.forEach { $0.want() } }
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
        settleFiling()
        refresh(scannedAt: scannedAt)
        applyCarriedNames()
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
        let hidden = Set(inHosts.keys).union(filed.filter { $0.key != $0.value.session }.values.map(\.session))
        let inner = Dictionary(
            (lastScan.values.joined()).compactMap { entry -> (String, AgentSession)? in
                inHosts[AgentSessionID.make(agent: entry.agent, native: entry.id)].map { ($0, entry) }
            }, uniquingKeysWith: { first, _ in first })
        for discovery in discoveries {
            let found = Self.newestOfEach(lastScan[discovery.kind.id] ?? []).compactMap { entry -> AgentSession? in
                let id = AgentSessionID.make(agent: entry.agent, native: entry.id)
                guard !hidden.contains(id) else { return nil }
                guard let process = inner[id] else { return entry }
                var hosted = entry
                hosted.innerAgent = process.agent
                hosted.setup = process.setup
                hosted.state = process.state
                return hosted
            }
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
        let hostPlaces = lastExtras.values.reduce(into: [String: AgentPlace]()) { places, extras in
            places.merge(extras.places) { kept, _ in kept }
        }
        let hostListed = lastExtras.values.reduce(into: Set<String>()) { $0.formUnion($1.listed) }
        directory.update(
            entries: entries, live: live, titles: shown, nativeNames: nativeNames, running: stillRunning, excluded: excluded,
            places: (placeTracker?.places ?? [:]).merging(hostPlaces) { tracked, _ in tracked },
            unplaced: placeTracker.map { tracker in
                tracker.unchecked(entries.map { AgentSessionID.make(agent: $0.agent, native: $0.id) })
                    .subtracting(tracker.places.keys).subtracting(hostListed)
            } ?? [], unreadSince: placeTracker?.failingSince ?? [:])
        let reported = namesNotSaved
        rememberNames()
        lastUsed = lastUsed.filter { handle(of: $0.key) != nil }
        let listed = Set((directory.conversations + directory.disconnected).map(\.id))
        pruneHostFollows(listed: listed)
        placeTracker?.notice(Set(placeQueries.map(\.id)))
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

    private func host(of conversation: AgentConversation) -> (HostDiscovery, AgentHostLocation)? {
        guard let location = conversation.host, let source = hosts.first(where: { $0.kind.id == location.host }), source.isEnabled
        else { return nil }
        return (source, location)
    }

    static let defaultHostDeadline: Duration = .seconds(2)

    private static func within<T: Sendable>(_ deadline: Duration, otherwise late: T, _ call: @escaping @MainActor () async -> T) async -> T {
        let answer = Once<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
                answer.wait(continuation)
                answer.start(Task { @MainActor in answer.resume(await call()) })
                Task {
                    try? await Task.sleep(for: deadline)
                    answer.giveUp(late)
                }
            }
        } onCancel: {
            answer.giveUp(late)
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        private var early: T?
        private var done = false
        private var work: Task<Void, Never>?

        func wait(_ continuation: CheckedContinuation<T, Never>) {
            let answered = lock.withLock {
                if early == nil { self.continuation = continuation }
                return early
            }
            if let answered { continuation.resume(returning: answered) }
        }

        func start(_ task: Task<Void, Never>) {
            if lock.withLock({ work = task; return done }) { task.cancel() }
        }

        @discardableResult
        func resume(_ value: T) -> Bool {
            let (won, waiting): (Bool, CheckedContinuation<T, Never>?) = lock.withLock {
                guard !done else { return (false, nil) }
                done = true
                defer { continuation = nil }
                if continuation == nil { early = value }
                return (true, continuation)
            }
            waiting?.resume(returning: value)
            return won
        }

        func giveUp(_ late: T) {
            guard resume(late) else { return }
            lock.withLock { work }?.cancel()
        }
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
        hostOwned = hostOwned.filter(kept)
        loadedVersions = loadedVersions.filter { kept($0.key) }
        environments = environments.filter { keptEnvironment?($0.key) ?? kept($0.key) }
        prompts = prompts.filter { kept($0.key) }
        connectorNames = connectorNames.filter { kept($0.key) }
        connectorNamesAt = connectorNamesAt.filter { kept($0.key) }
        labels = labels.filter { kept($0.key) }
        turns = turns.filter { kept($0.key) }
        forgetSteered { !kept($0.conversation) }
        leftInBox = leftInBox.filter { kept($0.key) }
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

    static let footerNameLimit = 20

    static func updateStep(_ kind: AgentKind) -> String {
        kind.reloadCommand ?? kind.resumeCommand.map { "restart with \($0)" } ?? "restart"
    }

    static func footerLabel(_ handle: String, reload: String?) -> String {
        guard let reload else { return "\u{201C}\(handle)\u{201D}" }
        let name = handle.count > footerNameLimit
            ? String(handle.prefix(footerNameLimit)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : handle
        return "\u{201C}\(name)\u{201D} \u{00B7} Update: \(reload)"
    }

    private func sendLabels() {
        for conversation in directory.conversations where conversation.connectorLive {
            guard features[conversation.id]?.contains("label") == true else { continue }
            let reload = runsOlderConnector(conversation) ? kind(of: conversation.id).map(Self.updateStep) : nil
            let label = Self.footerLabel(conversation.handle, reload: reload)
            guard labels[conversation.id] != label else { continue }
            labels[conversation.id] = label
            transport.enqueue(.status(id: makeId(), expectedSession: conversation.id, text: label), for: conversation.id)
        }
    }

    func deliver(_ text: String, to id: String, request: String? = nil, images: [String] = [], inFront: Bool = false) async -> AgentReceipt {
        if let source = startingHost(id) { return await start(text, through: source, request: request ?? makeId(), inFront: inFront) }
        if exclusions.excludes(id) { return .notSent(disconnected.first { $0.id == id }?.handle, reason: .disconnected) }
        guard let conversation = directory.conversations.first(where: { $0.id == id }) else {
            return .notSent(nil, reason: .conversationEnded)
        }
        lastUsed[id] = now()
        let handle = conversation.handle
        if let (source, location) = host(of: conversation) {
            let request = request ?? makeId()
            remember(asked: text, for: request)
            let follows = conversation.connectorLive && features[id]?.contains("promptDigest") == true
            if follows {
                delivering[request] = id
                hostFollows[id, default: []].append(HostFollow(prompt: AgentPromptDigest.of(text), request: request, expires: nil))
                if hostFollows[id, default: []].count > Self.hostFollowLimit { hostFollows[id]?.removeFirst() }
            }
            if inFront, images.isEmpty, showsDraft(id), hostOwned.contains(id), joinsDrafts(id), transport.isLive(session: id) {
                startTrace(request, in: id)
                let joined = await joinDraft(text, in: id)
                let waitEnds = now().addingTimeInterval(Self.hostTurnWait)
                switch joined {
                case .sent:
                    trace(request) {
                        $0.withDraft = true
                        $0.confirmed = now()
                    }
                    settleHostDelivery(request, in: id, expires: waitEnds)
                    if follows, running[id] != nil, let turn = turns[id] { follow(turn, of: id, for: request) }
                    return .sentWithDraft(handle)
                case .kept(let reason):
                    stopFollowingHosted(request, in: id)
                    return .kept(handle, reason: reason)
                case .unknown:
                    if follows { uncertainHosted[request] = (handle, id, true) }
                    settleHostDelivery(request, in: id, expires: waitEnds)
                    return .uncertain(handle)
                case .empty:
                    break
                }
            }
            let answer = await Self.within(receiptTimeout, otherwise: AgentHostDelivery.uncertain, {
                await source.host.deliver(text, images: images, request: request, to: location)
            })
            let arrived = matched.remove(request) != nil
            let waitEnds = now().addingTimeInterval(Self.hostTurnWait)
            switch answer {
            case .accepted:
                settleHostDelivery(request, in: id, expires: waitEnds)
                if follows, running[id] != nil, let turn = turns[id] { follow(turn, of: id, for: request) }
                return .sent(handle)
            case .queued:
                settleHostDelivery(request, in: id, expires: nil)
                let waiting = (directory.conversations.first { $0.id == id }?.state ?? .working).named(by: waitingPrompts[id])
                if case .queue(let reason) = AgentDeliveryPolicy.decide(AgentDeliveryContext(state: waiting)) { return .queued(handle, waitingOn: reason) }
                return .queued(handle)
            case .uncertain where arrived:
                settleHostDelivery(request, in: id, expires: waitEnds)
                return .sent(handle)
            case .uncertain:
                if follows { uncertainHosted[request] = (handle, id, false) }
                settleHostDelivery(request, in: id, expires: waitEnds)
                return .uncertain(handle)
            case .refused(let why):
                stopFollowingHosted(request, in: id)
                return .notSent(handle, reason: .refused(why))
            case .unsupported:
                stopFollowingHosted(request, in: id)
            }
        }
        let message = AgentOutbox.Message(id: request ?? makeId(), conversation: id, text: text, images: images)
        let merge = inFront && joinsDrafts(id)
        switch outbox.send(
            message, state: state(of: id), canEnterPromptBox: inFront && takesPromptBox(id, images: images), canSteer: steers(id)
        ) {
        case .handOff:
            return await withCheckedContinuation { continuation in
                waiters[message.id] = continuation
                handOff(message, handle: handle, merge: merge)
            }
        case .enterPromptBox:
            return await withCheckedContinuation { continuation in
                waiters[message.id] = continuation
                handOff(message, handle: handle, box: true, merge: merge)
            }
        case .queue(let reason):
            return .queued(handle, waitingOn: reason)
        case .needsReview(let reason):
            return .kept(handle, reason: Self.kept(reason))
        case .disconnected:
            if let (source, _) = host(of: conversation) { return .notSent(handle, reason: .hostTakesNoMessages(source.kind.displayName)) }
            return .notSent(handle, reason: .connectorNotRunning)
        }
    }

    func prepare(for hello: AgentEvent.Hello) {
        guard !exclusions.excludes(hello.session) else { return }
        if hello.resumesAfterGap { outbox.noteConnectionGap(conversation: hello.session) }
        running[hello.session] = hello.knownIdle ? nil : now()
        turns[hello.session] = hello.reportsTurn && !hello.knownIdle ? hello.turn.flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    func retire(installation: String) {
        let retiring = Set(installations.filter { $0.value == installation }.keys)
        guard !retiring.isEmpty else { return }
        let kept = { (session: String) in !retiring.contains(session) }
        awaitingResult = awaitingResult.filter { kept($0.key) }
        awaitedRequests = awaitedRequests.filter { kept($0.key) }
        nextTyped = nextTyped.filter { kept($0.key) }
        absorbed = absorbed.filter { kept($0.key) }
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
            if let inner = filed[session]?.session, inner != session, let (innerAgent, innerNative) = AgentSessionID.split(inner) {
                discoveries.first { $0.kind.id == innerAgent }?.observe(event.renamingSession { _ in innerNative })
            }
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
            if hosts.contains(where: { $0.kind.id == hello.agent }) { hostOwned.insert(hello.session) } else { hostOwned.remove(hello.session) }
            installations[hello.session] = hello.installation
            loadedVersions[hello.session] = hosts.contains { $0.kind.id == hello.agent } ? nil : hello.codeVersion
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
            expectListing(hello)
            refresh(nameReportedFor: hello.session)
            readPlaces()
            Task { [weak self] in await self?.rescan(rereadingTitles: true) }
        case .title(let session, let text):
            connectorNames[session] = .some(text.isEmpty ? nil : text)
            connectorNamesAt[session] = now()
            refresh(nameReportedFor: session)
            Task { [weak self] in await self?.rescan(rereadingTitles: true) }
        case .waiting(let session, let prompt):
            let changed = waitingPrompts[session] != prompt
            waitingPrompts[session] = prompt
            if changed { onChange?() }
            Task { [weak self] in await self?.rescan(rereadingTitles: false) }
        case .notify(let session, let turn, let on):
            _ = notify(session: session, turn: turn, on: on)
        case .shown(let session, let on, let draft, let newConversation):
            guard let host = AgentSessionID.split(session)?.agent, hosts.contains(where: { $0.kind.id == host }) else { break }
            let slot = Self.slot(host, Self.instance(of: session))
            shownByHost[slot] = on ? session : nil
            shownWithDraft[slot] = on && draft ? session : nil
            newConversationShown[slot] = !on && newConversation ? session : nil
        case .focused(let request):
            focusWaiters.removeValue(forKey: request)?.resume(returning: .selected)
        case .ack:
            break
        case .submitted(let request, _, let report) where hostStarts[request] != nil:
            hostStarts.removeValue(forKey: request)?.resume(returning: .sent(withDraft: report.withDraft))
        case .refused(let request, let reason, let detail) where hostStarts[request] != nil:
            hostStarts.removeValue(forKey: request)?.resume(returning: reason == Self.unclearRefusal ? .unknown : .refused(reason, detail: detail))
        case .undelivered(let request, _, let mayHaveArrived) where hostStarts[request] != nil:
            hostStarts.removeValue(forKey: request)?.resume(returning: mayHaveArrived ? .unknown : .refused("", detail: nil))
        case .submitted(let request, _, _) where hostJoins[request] != nil:
            hostJoins.removeValue(forKey: request)?.resume(returning: .sent)
        case .refused(let request, let reason, _) where hostJoins[request] != nil:
            hostJoins.removeValue(forKey: request)?.resume(returning: Self.hostJoin(refusal: reason))
        case .undelivered(let request, _, let mayHaveArrived) where hostJoins[request] != nil:
            hostJoins.removeValue(forKey: request)?.resume(returning: mayHaveArrived ? .unknown : .empty)
        case .submitted(let request, let turn, let report):
            confirm(request, turn: turn, report: report)
        case .checked(_, let check, let report) where promptBoxChecks[check] != nil:
            promptBoxChecks.removeValue(forKey: check)?.resume(returning: report.promptBox == "ready")
        case .refused(let check, _, _) where promptBoxChecks[check] != nil, .undelivered(let check, _, _) where promptBoxChecks[check] != nil:
            promptBoxChecks.removeValue(forKey: check)?.resume(returning: false)
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
        case .refused(let request, let reason, _) where focusWaiters[request] != nil:
            focusWaiters.removeValue(forKey: request)?.resume(returning: reason == "unknownFocus" ? .outdated : .notFound)
        case .undelivered(let request, _, _) where focusWaiters[request] != nil:
            focusWaiters.removeValue(forKey: request)?.resume(returning: .notFound)
        case .refused(let request, let reason, _):
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
        case .absorbed(let session, let turn, let prompt):
            if let pending = nextTyped[session], pending.prompt == prompt {
                nextTyped[session] = nil
                follow(turn, of: session, for: pending.request)
            } else {
                absorbed[session] = (turn, prompt)
            }
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
            if handle(of: session) != nil { noteUsed(session) }
        case .turnStarted(let session, let turn, let prompt):
            if let awaited = awaitingResult[session], awaited != turn { stopAwaiting(session) }
            if nextRequested.remove(session) != nil { waitForReply(turn, of: session, requested: true) }
            if let prompt { followHosted(turn, of: session, prompt: prompt) }
            let awaitsAbsorbed = prompt == nil && nextTyped[session]?.prompt != nil
            if !awaitsAbsorbed, let pending = nextTyped.removeValue(forKey: session), let typedAt = pending.typedAt,
               pending.prompt.map({ $0 == prompt }) ?? (now().timeIntervalSince(typedAt) <= typedTurnWindow) {
                waitForReply(turn, of: session, requested: false)
                awaitedRequests[session] = pending.request
                forgetSteered { $0.request == pending.request }
            }
            if let pending = handingOff[session], requests[pending] != nil { requests[pending]?.turnDuringHandOff = .started(turn) }
            if let (request, _) = requests.first(where: { $0.value.message.conversation == session && $0.value.followsNextTurn }) {
                requests[request]?.followsNextTurn = false
                follow(turn, of: session, for: request)
            }
            handingOff[session] = nil
            running[session] = now()
            turns[session] = turn
            if hostOwned.contains(session) { Task { [weak self] in await self?.rescan(rereadingTitles: false) } }
        case .turnComplete(let session, let reason, let answer, let after):
            absorbed[session] = nil
            handingOff[session] = nil
            for (id, entry) in requests where entry.message.conversation == session && entry.turnDuringHandOff != nil {
                requests[id]?.turnDuringHandOff = .ended
            }
            running[session] = nil
            turns[session] = nil
            if awaitingResult[session] != nil {
                let wasRequested = requested.contains(session)
                let origin = awaitedRequests[session]
                stopAwaiting(session)
                let handle = handle(of: session) ?? ""
                let dictated = origin.flatMap(forgetAsked)
                if reason == "answer" || reason == "complete" {
                    let cause = SpokenResult.cause(after: after, asked: dictated)
                    announce(result: origin) { [weak self] in self?.onResult?(session, handle, answer, wasRequested, origin, cause) }
                } else if let body = SpokenResult.ending(reason) {
                    announce(result: origin) { [weak self] in self?.onEnded?(session, handle, body, wasRequested, origin) }
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
        if let holder = heldByItsHost(session) {
            if on, turns[holder] == nil, running[holder] != nil { return false }
            return notify(session: holder, turn: turns[holder] ?? "", on: on)
        }
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

    static let hostFollowLimit = 16
    static let steeredLimit = 64
    static let hostTurnWait: TimeInterval = 300

    private struct HostFollow {
        var prompt: String
        var request: String
        var expires: Date?
        var known: Set<String> = []
    }

    private struct Filing {
        var session: String
        var instance: String
    }

    private struct ProcessIdentity {
        var own: [String: String]
        var parent: [String: String]
    }

    private func settleHostDelivery(_ request: String, in conversation: String, expires: Date?) {
        delivering[request] = nil
        if let index = hostFollows[conversation]?.firstIndex(where: { $0.request == request }) { hostFollows[conversation]?[index].expires = expires }
        guard let speak = heldResults.removeValue(forKey: request), !exclusions.excludes(conversation) else { return }
        speak()
    }

    private func stopFollowingHosted(_ request: String, in conversation: String) {
        delivering[request] = nil
        heldResults[request] = nil
        uncertainHosted[request] = nil
        hostFollows[conversation]?.removeAll { $0.request == request }
        if awaitedRequests[conversation] == request { stopAwaiting(conversation) }
    }

    private func followHosted(_ turn: String, of session: String, prompt: String) {
        let at = now()
        let fits = { (follow: HostFollow) in follow.prompt == prompt && follow.expires.map { $0 > at } ?? true }
        let request: String
        if let match = hostFollows[session]?.firstIndex(where: fits), let found = hostFollows[session]?.remove(at: match).request {
            request = found
        } else if let host = AgentSessionID.agent(of: session), case let copy = Self.slot(host, Self.instance(of: session)),
                  let match = startFollows[copy]?.firstIndex(where: { fits($0) && !$0.known.contains(session) }),
                  let found = startFollows[copy]?.remove(at: match).request {
            request = found
        } else {
            return
        }
        if delivering[request] != nil { matched.insert(request) }
        follow(turn, of: session, for: request)
        if let doubted = uncertainHosted.removeValue(forKey: request) {
            onNotice?(doubted.withDraft ? .sentWithDraft(doubted.handle) : .sent(doubted.handle), request, session)
        }
    }

    private func announce(result origin: String?, _ speak: @escaping () -> Void) {
        guard let origin, delivering[origin] != nil else { return speak() }
        heldResults[origin] = speak
    }

    func filing(for hello: AgentEvent.Hello) -> String? {
        if isHostsOwn(hello) {
            if let holder = filed[hello.session], holder.instance != hello.instance {
                filed[hello.session] = nil
                transport.rehello(session: hello.session)
            }
            filed[hello.session] = Filing(session: hello.session, instance: hello.instance)
            return nil
        }
        filed = filed.filter { $0.value.session != hello.session }
        guard let claimed = hostedConversation(claimedBy: hello.session) else {
            rehelloAsked.remove(hello.session)
            return nil
        }
        if let holder = filed[claimed], holder.instance != hello.instance, transport.isLive(session: claimed) {
            rehelloAsked.insert(hello.session)
            return nil
        }
        rehelloAsked.remove(hello.session)
        filed[claimed] = Filing(session: hello.session, instance: hello.instance)
        return claimed
    }

    private func settleFiling() {
        silenceHostsTurnedOff()
        let identities = hosts.filter { $0.isEnabled && !$0.host.identityKeys.isEmpty }
        let hosted = Set(hosts.flatMap { source in
            source.isEnabled ? (lastScan[source.kind.id] ?? []).map { AgentSessionID.make(agent: $0.agent, native: $0.id) } : []
        })
        for (conversation, _) in filed where !hosted.contains(conversation) {
            filed[conversation] = nil
            if transport.isLive(session: conversation) { transport.rehello(session: conversation) }
        }
        var released: Set<String> = []
        for (conversation, holder) in filed where holder.session == conversation && !transport.isLive(session: conversation) {
            filed[conversation] = nil
            released.insert(conversation)
        }
        var claims: [String: String] = [:]
        var seen: Set<String> = []
        if !identities.isEmpty {
            let hostKinds = Set(hosts.map(\.kind.id))
            for discovery in discoveries where !hostKinds.contains(discovery.kind.id) {
                for entry in lastScan[discovery.kind.id] ?? [] {
                    let session = AgentSessionID.make(agent: entry.agent, native: entry.id)
                    if let key = processKey(entry) { seen.insert(key) }
                    guard let conversation = hostedConversation(claimedBy: session, among: hosted) else { continue }
                    claims[session] = conversation
                    guard filed[conversation]?.session != session, !rehelloAsked.contains(session) || released.contains(conversation),
                          transport.isLive(session: session)
                    else { continue }
                    rehelloAsked.insert(session)
                    transport.rehello(session: session)
                }
            }
        }
        processIdentities = processIdentities.filter { seen.contains($0.key) }
        expected = expected.filter { !hosted.contains($0) }
        for (session, conversation) in claims where inHosts[session] != conversation { carry(from: session, to: conversation) }
        for (session, conversation) in inHosts where claims[session] == nil && !hosted.contains(conversation) {
            carry(from: conversation, to: session)
        }
        inHosts = claims
        for (session, conversation) in claims { linked[conversation] = session }
    }

    private func expectListing(_ hello: AgentEvent.Hello) {
        guard AgentSessionID.agent(of: hello.session) == hello.agent, !Self.carriesNewConversations(hello.session),
              let source = hosts.first(where: { $0.kind.id == hello.agent }), source.isEnabled,
              !(lastScan[source.kind.id] ?? []).contains(where: { AgentSessionID.make(agent: $0.agent, native: $0.id) == hello.session }),
              expected.insert(hello.session).inserted
        else { return }
        source.expect()
    }

    private func isHostsOwn(_ hello: AgentEvent.Hello) -> Bool {
        guard AgentSessionID.agent(of: hello.session) == hello.agent,
              let source = hosts.first(where: { $0.kind.id == hello.agent }), source.isEnabled
        else { return false }
        return (lastScan[source.kind.id] ?? []).contains { AgentSessionID.make(agent: $0.agent, native: $0.id) == hello.session }
    }

    private func counterpart(of id: String) -> String? {
        linked[id] ?? linked.first { $0.value == id }?.key
    }

    private func carry(from old: String, to new: String) {
        if exclusions.isKnown, exclusions.excludes(old), exclusions.insert(new) { saveExclusions() }
        if let used = lastUsed[old], used > lastUsed[new] ?? .distantPast { lastUsed[new] = used }
        if directory.chosenNames[old] != nil { carriedNames[new] = old }
    }

    private func applyCarriedNames() {
        let carried = carriedNames
        carriedNames = [:]
        guard namesProblem == nil else { return }
        var next = directory
        let moved = carried.filter { next.carryChosenName(from: $0.value, to: $0.key) }
        guard !moved.isEmpty else { return }
        directory = next
        do {
            try nameStore?.save(directory.chosenNames, remembered: directory.remembered, excluded: exclusions.excluded)
            savedRemembered = directory.remembered
        } catch {
            namesNotSaved = error.localizedDescription
            Log.agents.error("conversation names not saved: \(error.localizedDescription, privacy: .public)")
        }
        sendLabels()
        onChange?()
    }

    private func heldByItsHost(_ session: String) -> String? {
        guard let conversation = hostedConversation(claimedBy: session), conversation != session,
              filed[conversation]?.session == conversation, transport.isLive(session: conversation)
        else { return nil }
        return conversation
    }

    private func hostedConversation(claimedBy session: String, among hosted: Set<String>? = nil) -> String? {
        guard let (agent, native) = AgentSessionID.split(session),
              let entry = (lastScan[agent] ?? []).first(where: { $0.id == native }), let key = processKey(entry), let pid = entry.pid
        else { return nil }
        let identities = hosts.filter { $0.isEnabled && !$0.host.identityKeys.isEmpty }
        guard !identities.isEmpty else { return nil }
        let keys = Set(identities.flatMap(\.host.identityKeys))
        let identity = processIdentities[key] ?? ProcessIdentity(
            own: processEnvironment(pid, keys), parent: processParent(pid).map { processEnvironment($0, keys) } ?? [:])
        processIdentities[key] = identity
        let listed = hosted ?? Set(identities.flatMap { source in
            (lastScan[source.kind.id] ?? []).map { AgentSessionID.make(agent: $0.agent, native: $0.id) }
        })
        for source in identities {
            guard let location = source.host.location(in: identity.own), location.host == source.kind.id,
                  source.host.location(in: identity.parent) != location
            else { continue }
            let conversation = AgentSessionID.make(agent: source.kind.id, native: location.conversationKey)
            if listed.contains(conversation) { return conversation }
            if expected.insert(conversation).inserted {
                source.expect()
                Task { [weak self] in await self?.rescan(rereadingTitles: false) }
            }
        }
        return nil
    }

    private func pruneHostFollows(listed: Set<String>) {
        let at = now()
        hostFollows = hostFollows.filter { listed.contains($0.key) }.mapValues { follows in
            follows.filter { follow in follow.expires.map { $0 > at } ?? true }
        }
        let following = Set(hostFollows.values.joined().map(\.request))
        uncertainHosted = uncertainHosted.filter { following.contains($0.key) }
    }

    private func processKey(_ entry: AgentSession) -> String? {
        entry.pid.map { "\($0):\(entry.startedAt ?? 0)" }
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
        if handingOff[id] != nil { return .working }
        if running[id] != nil, conversation.state == .idle { return .working }
        return conversation.state.named(by: waitingPrompts[id])
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

    private func remember(asked text: String, for request: String) {
        guard asked.updateValue(text, forKey: request) == nil else { return }
        askedOrder.append(request)
        if askedOrder.count > Self.keptDeliveries { asked[askedOrder.removeFirst()] = nil }
    }

    private func forgetAsked(_ request: String) -> String? {
        askedOrder.removeAll { $0 == request }
        return asked.removeValue(forKey: request)
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
        let conversation = requests[request]?.message.conversation
        if let conversation, turn.isEmpty, features[conversation]?.contains("steer") == true, let entry = requests[request] {
            steered.append(Steered(wire: entry.wire, request: request, handle: entry.handle, conversation: conversation))
            if steered.count > Self.steeredLimit, let oldest = steered.first { forgetSteered { $0.wire == oldest.wire } }
            followSteer(of: conversation, for: request, text: entry.message.text)
        }
        if let conversation, !turn.isEmpty, awaitingResult[conversation] != turn {
            stopAwaiting(conversation)
            awaitingResult[conversation] = turn
            awaitedRequests[conversation] = request
        }
        let handle = requests[request]?.handle ?? ""
        settle(request, report.withDraft ? .sentWithDraft(handle) : .sent(handle))
        if let conversation, handingOff[conversation] == request, features[conversation]?.contains("steer") == true {
            handingOff[conversation] = nil
            releaseHeld()
        }
    }

    private func follow(_ turn: String, of conversation: String, for request: String) {
        defer { forgetSteered { $0.request == request } }
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
        if requests[request] == nil, let index = steered.firstIndex(where: { $0.wire == request }) {
            return refuseSteered(steered.remove(at: index), reason: reason)
        }
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
        case "dialog" where entry.box && !entry.timedOut:
            requests[request] = nil
            retries[request] = entry.retry + 1
            let held = outbox.send(entry.message, state: AgentLiveState.userDialog.named(by: waitingPrompts[entry.message.conversation]))
            report(.queued(handle, waitingOn: { if case .queue(let reason) = held { reason } else { .userDialog } }()), for: request, in: entry.message.conversation)
            return
        case "filled" where entry.box:
            filledWires[request] = entry.wire
            settle(request, .kept(handle, reason: .inPromptBox(.awaitingReturn)))
        case "added": settle(request, .kept(handle, reason: .inPromptBox(.besideText)))
        case "joined", "joinedMidTurn":
            filledWires[request] = entry.wire
            trace(request) { $0.withDraft = true }
            settle(request, .kept(handle, reason: .inPromptBox(reason == "joined" ? .joinedDraft : .joinedDraftMidTurn)))
        case "filled":
            filledWires[request] = entry.wire
            settle(request, Self.filled(handle: handle, features: features[entry.message.conversation]))
        case "dialog": settle(request, .kept(handle, reason: .dialog))
        default: settle(request, .notSent(handle, reason: Self.notSent(reason)))
        }
        releaseHeld()
    }

    func settleLeftInPromptBox(_ request: String, in conversation: String, as receipt: AgentReceipt?) {
        let left = leftInBox.removeValue(forKey: conversation)?.map(\.request) ?? [request]
        for one in left {
            filledWires[one] = nil
            if let receipt { report(receipt, for: one, in: conversation) } else { onForget?(one) }
        }
    }

    func awaitsLateOutcome(_ request: String) -> Bool {
        steered.contains { $0.request == request }
    }

    private func forgetSteered(_ matches: (Steered) -> Bool) {
        let forgotten = steered.filter(matches)
        steered.removeAll(where: matches)
        for late in forgotten { onForget?(late.request) }
    }

    private func refuseSteered(_ late: Steered, reason: String) {
        if nextTyped[late.conversation]?.request == late.request { nextTyped[late.conversation] = nil }
        if reason == "filled", let onLeftInPromptBox {
            filledWires[late.request] = late.wire
            guard leftInBox[late.conversation] == nil else {
                leftInBox[late.conversation]?.append(late)
                return
            }
            leftInBox[late.conversation] = [late]
            return onLeftInPromptBox(late.request, late.conversation, late.handle)
        }
        let receipt: AgentReceipt = switch reason {
        case "draft": .kept(late.handle, reason: .composing)
        case "filled": .kept(late.handle, reason: .inPromptBox(.afterStop))
        case "added": .kept(late.handle, reason: .inPromptBox(.besideText))
        default: .notSent(late.handle, reason: Self.notSent(reason))
        }
        report(receipt, for: late.request, in: late.conversation)
    }

    func takesPromptBox(_ id: String, images: [String]) -> Bool {
        images.isEmpty && checksPromptBox(id) && busyAndFree(id)
    }

    private func steers(_ id: String) -> Bool {
        features[id]?.contains("steer") == true && busyAndFree(id)
    }

    private func busyAndFree(_ id: String) -> Bool {
        guard handingOff[id] == nil, let conversation = directory.conversations.first(where: { $0.id == id }), conversation.connectorLive
        else { return false }
        return conversation.state == .working || (conversation.state == .idle && running[id] != nil)
    }

    func checksPromptBox(_ id: String) -> Bool { features[id]?.contains("box") == true }

    func joinsDrafts(_ id: String) -> Bool { features[id]?.contains("merge") == true }

    func showsDraft(_ id: String) -> Bool {
        guard let conversation = directory.conversations.first(where: { $0.id == id }), let (source, _) = host(of: conversation) else { return false }
        return shownWithDraft[Self.slot(source.kind.id, conversation.host?.instance)] == id
    }

    private func joinDraft(_ text: String, in id: String) async -> HostJoin {
        let wire = makeId()
        let wait = receiptTimeout
        transport.enqueue(.submit(id: wire, expectedSession: id, text: text, expiresAt: deadline(after: wait), merge: true), for: id)
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.hostJoins.removeValue(forKey: wire)?.resume(returning: .unknown)
        }
        return await withCheckedContinuation { hostJoins[wire] = $0 }
    }

    private static let unclearRefusal = "unclear"

    private static func hostJoin(refusal: String) -> HostJoin {
        switch refusal {
        case unclearRefusal: .unknown
        case "draft": .kept(.composing)
        case "added": .kept(.inPromptBox(.besideText))
        default: .empty
        }
    }

    func promptBoxReady(_ request: String, in conversation: String) async -> Bool {
        guard let wire = filledWires.removeValue(forKey: request) else { return false }
        let check = makeId()
        let wait = promptBoxCheckWait
        transport.enqueue(.check(id: check, expectedSession: conversation, request: wire, expiresAt: deadline(after: wait)), for: conversation)
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.promptBoxChecks.removeValue(forKey: check)?.resume(returning: false)
        }
        return await withCheckedContinuation { promptBoxChecks[check] = $0 }
    }

    func followSteer(of conversation: String, for request: String, text: String) {
        let prompt = AgentPromptDigest.of(text)
        if let early = absorbed.removeValue(forKey: conversation), early.prompt == prompt {
            follow(early.turn, of: conversation, for: request)
            return
        }
        nextTyped[conversation] = TypedTurn(request: request, typedAt: now(), prompt: prompt)
    }

    private func handOff(_ message: AgentOutbox.Message, handle: String, box: Bool = false, merge: Bool = false) {
        attempts += 1
        let attempt = attempts
        let entry = Request(message: message, handle: handle, attempt: attempt, retry: retries.removeValue(forKey: message.id) ?? 0, box: box)
        requests[message.id] = entry
        remember(asked: message.text, for: message.id)
        startTrace(message.id, in: message.conversation)
        handingOff[message.conversation] = message.id
        transport.enqueue(
            .submit(
                id: entry.wire, expectedSession: message.conversation, text: message.text,
                expectedPrompts: prompts[message.conversation], expiresAt: deadline(after: receiptTimeout),
                images: takesImages(message.conversation) ? message.images : [], box: box, merge: merge),
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
        case .refused(let wire, let reason, let detail):
            return request(wire).map { .refused(request: $0, reason: reason, detail: detail) }
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
        for release in outbox.release(state: state(of:), canSteer: steers) {
            let handle = handle(of: release.message.conversation)
            switch release.decision {
            case .handOff, .enterPromptBox:
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

    func takesImages(_ session: String) -> Bool {
        if let conversation = directory.conversations.first(where: { $0.id == session }), let (source, _) = host(of: conversation) {
            return source.host.takesImages
        }
        return features[session]?.contains("images") == true
    }

    static func filled(handle: String, features: Set<String>?) -> AgentReceipt {
        features?.contains("fill") == true ? .kept(handle, reason: .inPromptBox(.afterStop)) : .notSent(handle, reason: .stopped)
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
        setups: ConnectorSetupRegistry, legacyAgent: String, hosts: [AgentHostIntegration] = [],
        hostAllowed: @escaping @MainActor (String) -> Bool
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
                    let filed = box.hub?.filing(for: hello)
                    var greeted = hello
                    if let filed { greeted.session = filed }
                    box.hub?.prepare(for: greeted)
                    done(filed)
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
                plan: AgentTerminalFocus.plan(surfaces), connector: { session, definition in await box.hub?.focusInPlace(session, definition: definition) ?? .notFound },
                noun: AgentTerminalFocus.noun(surfaces)),
            front: AgentFront(surfaces: surfaces), glance: AgentFront.confirmingWithoutAsking(surfaces), exclusions: exclusions,
            places: Self.places(surfaces: surfaces, sources: placeSources),
            hosts: hosts.map { $0.bound(to: setups) }, hostAllowed: hostAllowed,
            processEnvironment: { pid, keys in SystemTerminalFacts.arguments(of: pid, keeping: keys)?.environment ?? [:] },
            processParent: { SystemTerminalFacts.parent(of: $0) })
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
        await hub.rescan(rereadingTitles: false, wantingHosts: settingsOpen)
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
