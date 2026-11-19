import AppKit
import Foundation
import KeyScribeKit

@MainActor
final class OpencodeHost: AgentHost {

    nonisolated static let kind = AgentKind(id: OpencodeSession.agent, displayName: "OpenCode", connectorName: "OpenCode plugin")
    nonisolated static let integration: AgentHostIntegration = {
        var integration = AgentHostIntegration(kind: kind, make: { OpencodeHost() })
        integration.processRule = .opencode
        integration.withSurfaces = { _, surfaces in OpencodeHost(panes: HostPaneReader.reading(.opencode, surfaces: surfaces)) }
        return integration
    }()

    nonisolated static let callTimeout: TimeInterval = 3
    nonisolated static let streamSilence: TimeInterval = 30
    nonisolated static let paneLifetime: TimeInterval = 5
    nonisolated static let recentDelivery: TimeInterval = 300
    nonisolated static let listLimit = 50
    nonisolated static let recoverLimit = 4
    nonisolated static let eventBacklog = 1024
    nonisolated static let sentMemory = 32
    nonisolated static let notRunning = "OpenCode isn\u{2019}t running. Start opencode in a terminal to reach its conversations."
    nonisolated static let unanswered = "OpenCode\u{2019}s service didn\u{2019}t answer. Try again in a moment."

    private let instance: String
    private let service: @Sendable () -> OpencodeService?
    private let transport: any OpencodeTransport
    private let installed: () -> Bool
    private let panes: HostPaneReader.Read?
    private let showsWindowTitle: @Sendable () -> Bool
    private let frontmost: @MainActor () -> (app: AgentHostApp, title: String)?
    private let now: () -> Date

    private var turns = OpencodeTurns()
    private var sessions: [String: OpencodeSession] = [:]
    private var delivered: [String: Date] = [:]
    private var shownPanes: (at: Date, panes: [HostPane])?
    private var sent: [(message: String, request: String)] = []
    private var natives: [String: String] = [:]
    private var changed: (@MainActor (AgentHostChange) -> Void)?
    private var stream: (any OpencodeStream)?
    private var consumer: Task<Void, Never>?
    private var streamGeneration = 0
    private var connecting = false
    private var seeding: [Data]?

    init(
        instance: String = OpencodeService.registration(
            home: FileManager.default.homeDirectoryForCurrentUser.path, environment: ProcessInfo.processInfo.environment
        ).deletingLastPathComponent().path,
        service: (@Sendable () -> OpencodeService?)? = nil,
        transport: any OpencodeTransport = OpencodeHTTP(),
        installed: @escaping () -> Bool = { OpencodeInstall.find() != nil },
        panes: HostPaneReader.Read? = nil,
        showsWindowTitle: @escaping @Sendable () -> Bool = OpencodeHost.readsWindowTitle,
        frontmost: @escaping @MainActor () -> (app: AgentHostApp, title: String)? = HostFront.window,
        now: @escaping () -> Date = Date.init
    ) {
        self.instance = instance
        let registration = URL(fileURLWithPath: instance).appendingPathComponent("service.json")
        self.service = service ?? { OpencodeHost.registered(at: registration) }
        self.transport = transport
        self.installed = installed
        self.panes = panes
        self.showsWindowTitle = showsWindowTitle
        self.frontmost = frontmost
        self.now = now
    }

    nonisolated static func registered(at file: URL) -> OpencodeService? {
        guard let data = FileManager.default.contents(atPath: file.path), let service = OpencodeService.parse(data),
              let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              case .started(let started) = ProcessStart.read(pid: service.pid),
              LocalServiceRecord.trusts(processStarted: Date(timeIntervalSince1970: Double(started) / 1000), recordedAt: modified),
              let process = SystemTerminalFacts.arguments(of: service.pid, keeping: []), OpencodeInstall.isService(arguments: process.arguments)
        else { return nil }
        return service
    }

    nonisolated static func readsWindowTitle() -> Bool {
        let file = OpencodeInstall.tuiSettings(home: FileManager.default.homeDirectoryForCurrentUser.path, environment: ProcessInfo.processInfo.environment)
        return OpencodeInstall.showsWindowTitle(settings: FileManager.default.contents(atPath: file.path))
    }

    var isEnabled: Bool { installed() }

    var takesImages: Bool { true }

    func reportsTurns(at location: AgentHostLocation) -> Bool {
        following && owns(location)
    }

    var reportsDeliveredTurns: Bool { following }

    private var following: Bool { stream != nil && seeding == nil }

    func watch(_ changed: @escaping @MainActor (AgentHostChange) -> Void) {
        self.changed = changed
        Task { await ensureStream() }
    }

    func unwatch() {
        changed = nil
        dropStream()
    }

    private func owns(_ location: AgentHostLocation) -> Bool {
        location.host == Self.kind.id && location.instance == instance && !location.native.isEmpty
    }

    private func location(_ id: String) -> AgentHostLocation {
        AgentHostLocation(host: Self.kind.id, instance: instance, native: id)
    }

    private func key(_ id: String) -> String {
        let key = location(id).conversationKey
        natives[key] = id
        return key
    }

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, to service: OpencodeService) async -> OpencodeReply? {
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return await transport.call(method, path, body: data, to: service, timeout: Self.callTimeout)
    }

    private func get(_ path: String, from service: OpencodeService) async -> Data? {
        guard let reply = await call("GET", path, to: service), reply.ok else { return nil }
        return reply.body
    }

    func scan() async -> AgentHostScan {
        guard let service = service() else {
            dropStream()
            return .unreadable(Self.notRunning)
        }
        guard let list = await get("/api/session?parentID=null&archived=false&limit=\(Self.listLimit)", from: service).flatMap(OpencodeSessions.parse),
              let active = await get("/api/session/active", from: service).flatMap(OpencodeSessions.active)
        else { return .unreadable(Self.unanswered) }
        if changed == nil {
            async let permissions = get("/api/permission/request", from: service)
            async let forms = get("/api/form", from: service)
            let (pending, asked) = await (permissions, forms)
            if changed == nil, pending != nil, asked != nil { turns.reset(permissions: pending, forms: asked) }
        }
        sessions = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = await processes(showing: list)
        let cutoff = now().addingTimeInterval(-Self.recentDelivery)
        delivered = delivered.filter { $0.value > cutoff && sessions[$0.key] != nil }
        var listed: [AgentSession] = []
        var titles: [String: String] = [:]
        var shownInstead: [String: String] = [:]
        for session in list {
            let asking = turns.asking(session.id)
            let running = active.contains(session.id) || turns.running[session.id] != nil
            guard shown[session.id] != nil || running || asking != nil || delivered[session.id] != nil else { continue }
            var entry = session.agentSession(instance: instance, running: running, asking: asking)
            entry.pid = shown[session.id]
            listed.append(entry)
            if let title = session.shownTitle {
                if turns.titledByUser(session.id) { titles[key(session.id)] = title } else { shownInstead[key(session.id)] = title }
            }
        }
        if changed != nil { Task { await ensureStream() } }
        return .found(listed, titles: titles, shownInstead: shownInstead)
    }

    private func processes(showing list: [OpencodeSession]) async -> [String: Int] {
        guard let panes, showsWindowTitle() else { return [:] }
        let current: [HostPane]
        if let known = shownPanes, now().timeIntervalSince(known.at) < Self.paneLifetime {
            current = known.panes
        } else {
            let fresh = await panes { _ in true }
            let kept = (shownPanes?.panes ?? []).filter { fresh.unread.contains($0.pid) }
            current = fresh.panes + kept
            shownPanes = (fresh.unread.isEmpty ? now() : .distantPast, current)
        }
        var shown: [String: Set<Int>] = [:]
        for pane in current {
            guard let id = OpencodePaneTitle.session(in: pane.title, among: list) else { continue }
            shown[id, default: []].insert(pane.pid)
        }
        return shown.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    private func ensureStream() async {
        guard changed != nil, stream == nil, !connecting, let service = service() else { return }
        connecting = true
        defer { connecting = false }
        streamGeneration += 1
        let generation = streamGeneration
        let wasRunning = turns.running
        seeding = []
        let (events, sink) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(Self.eventBacklog))
        stream = transport.stream(
            from: service,
            onEvent: { data in if case .dropped = sink.yield(data) { sink.finish() } },
            onClose: { sink.finish() })
        consumer = Task { @MainActor [weak self] in
            for await data in events { self?.received(data, generation: generation) }
            self?.closed(generation: generation)
        }
        async let permissions = get("/api/permission/request", from: service)
        async let forms = get("/api/form", from: service)
        async let activeList = get("/api/session/active", from: service)
        let (pending, asked, activeData) = await (permissions, forms, activeList)
        guard generation == streamGeneration, stream != nil else { return }
        turns.reset(permissions: pending, forms: asked)
        let active = activeData.flatMap(OpencodeSessions.active) ?? Set(wasRunning.keys)
        for (session, turn) in wasRunning where !active.contains(session) {
            let recent = await get("/api/session/\(session)/message?limit=\(Self.recoverLimit)&order=desc", from: service)
            guard generation == streamGeneration, let ended = recent.flatMap(OpencodeMessages.lastTurn) else { continue }
            changed?(.event(.turnComplete(session: key(session), reason: ended.reason, answer: ended.answer, turn: turn)))
        }
        let queued = seeding ?? []
        seeding = nil
        for data in queued { apply(data) }
        changed?(.listing)
    }

    private func received(_ data: Data, generation: Int) {
        guard generation == streamGeneration else { return }
        if seeding != nil {
            seeding?.append(data)
            return
        }
        apply(data)
    }

    private func apply(_ data: Data) {
        var relist = false
        for change in turns.apply(data, key: key) {
            switch change {
            case .listing:
                relist = true
            case .delivered(let session, let message, let turn):
                guard let index = sent.firstIndex(where: { $0.message == message }) else { continue }
                changed?(.delivered(request: sent.remove(at: index).request, at: location(session), turn: turn))
            case .event(let event):
                changed?(.event(event))
                if let session = event.session.flatMap({ natives[$0] }), let state = state(after: event, in: session) {
                    changed?(.state(location(session), state))
                }
            }
        }
        if relist { changed?(.listing) }
    }

    private func state(after event: AgentEvent, in session: String) -> AgentLiveState? {
        switch event {
        case .turnStarted(_, _, nil): return .working
        case .turnComplete: return .idle
        case .waiting(_, let prompt?): return AgentLiveState.userDialog.named(by: prompt)
        case .waiting(_, nil): return turns.running[session] == nil ? .idle : .working
        default: return nil
        }
    }

    private func closed(generation: Int) {
        guard generation == streamGeneration else { return }
        stream?.cancel()
        stream = nil
        seeding = nil
        changed?(.listing)
    }

    private func dropStream() {
        streamGeneration += 1
        consumer?.cancel()
        consumer = nil
        stream?.cancel()
        stream = nil
        seeding = nil
    }

    func deliver(_ text: String, images: [String], request: String, to location: AgentHostLocation) async -> AgentHostDelivery {
        guard owns(location) else { return .refused("OpenCode no longer lists this conversation.") }
        guard let service = service() else { return .refused(Self.notRunning) }
        let id = OpencodeMessages.messageId(request: request)
        var body: [String: Any] = ["id": id, "text": text, "delivery": "steer"]
        if !images.isEmpty { body["files"] = images.map { ["uri": URL(fileURLWithPath: $0).absoluteString] } }
        sent.append((id, request))
        if sent.count > Self.sentMemory { sent.removeFirst(sent.count - Self.sentMemory) }
        guard let reply = await call("POST", "/api/session/\(location.native)/prompt", body, to: service) else { return .uncertain }
        if reply.ok {
            guard OpencodeMessages.isMessage(reply.body, id: id) else { return .uncertain }
            delivered[location.native] = now()
            return turns.asking(location.native) == nil ? .accepted : .queued
        }
        if (400..<500).contains(reply.status) {
            sent.removeAll { $0.message == id }
            return .refused("OpenCode did not take the message.")
        }
        return .uncertain
    }

    func confirm(request: String, at location: AgentHostLocation) async -> Bool? {
        guard owns(location), let service = service() else { return nil }
        let id = OpencodeMessages.messageId(request: request)
        guard let reply = await call("GET", "/api/session/\(location.native)/message/\(id)", to: service) else { return nil }
        if reply.ok, OpencodeMessages.isMessage(reply.body, id: id) { return true }
        guard let inbox = await get("/api/session/\(location.native)/inbox", from: service) else { return nil }
        let waiting = (try? JSONSerialization.jsonObject(with: inbox) as? [String: Any])?["data"] as? [[String: Any]]
        return waiting?.contains { $0["id"] as? String == id } ?? false
    }

    func rename(_ location: AgentHostLocation, to name: String) async -> Bool {
        guard owns(location), let service = service() else { return false }
        return await call("PATCH", "/api/session/\(location.native)", ["title": name], to: service)?.ok == true
    }

    func front(among locations: [AgentHostLocation], reported: AgentHostLocation?, in app: AgentHostApp?) async -> AgentHostFront {
        guard showsWindowTitle(), let (app, title) = frontmost() else { return .unknown }
        let ours = locations.filter(owns)
        let candidates = ours.compactMap { sessions[$0.native] }
        guard let id = OpencodePaneTitle.session(in: title, among: candidates), let shown = ours.first(where: { $0.native == id }) else { return .unknown }
        return .shown(shown, in: app)
    }
}
