import AppKit
import Foundation
import KeyScribeKit

struct CodexPane: Equatable, Sendable {
    var pid: Int
    var title: String
}

@MainActor
final class CodexHost: AgentHost {
    typealias Connect = @Sendable (
        _ home: String, _ onNotification: @escaping @Sendable (CodexNotification) -> Void, _ onClose: @escaping @Sendable () -> Void
    ) async -> CodexDaemonClient?
    typealias Panes = @Sendable (_ home: String) async -> [CodexPane]

    nonisolated static let homeVariable = AgentProcesses.Rule.codex.setupVariable
    nonisolated static let kind = AgentKind(id: CodexThread.agent, displayName: "Codex", connectorName: "Codex plugin")
    nonisolated static let integration: AgentHostIntegration = {
        var integration = AgentHostIntegration(kind: kind, make: { CodexHost(enrolled: { [] }) })
        integration.connector = { CodexConnector(agentsDir: $0, pluginName: $1) }
        integration.folderVariable = homeVariable
        integration.processRule = .codex
        integration.report = { body, folder in CodexHookReport.events(body, instance: folder) }
        integration.withSetups = { setups in CodexHost(enrolled: { setups.setups?.enrolled(agent: kind.id).map(\.folder) ?? [] }) }
        integration.withSurfaces = { setups, surfaces in
            CodexHost(enrolled: { setups.setups?.enrolled(agent: kind.id).map(\.folder) ?? [] }, panes: CodexHost.panes(surfaces: surfaces))
        }
        return integration
    }()

    nonisolated static let callTimeout: TimeInterval = 3
    nonisolated static let pageLimit = 10
    nonisolated static let paneLifetime: TimeInterval = 5
    nonisolated static let ownPromptMemory = 16

    private final class Home {
        var client: CodexDaemonClient?
        var generation = 0
        var threads: [String: CodexThread] = [:]
        var foreignPrompt: [String: Date] = [:]
        var panes: (at: Date, panes: [CodexPane])?
    }

    private let enrolled: @MainActor () -> [String]
    private let installed: () -> Bool
    private let connect: Connect
    private let panes: Panes?
    private let frontmost: @MainActor () -> (app: AgentHostApp, title: String)?
    private let confirmEvery: TimeInterval
    private let confirmFor: TimeInterval
    private let now: () -> Date
    private var homes: [String: Home] = [:]
    private var ownPrompts: [String] = []
    private var changed: (@MainActor (AgentHostChange) -> Void)?

    init(
        enrolled: @escaping @MainActor () -> [String], installed: @escaping () -> Bool = { CodexInstall.find() != nil },
        connect: @escaping Connect = CodexHost.connect, panes: Panes? = nil,
        frontmost: @escaping @MainActor () -> (app: AgentHostApp, title: String)? = CodexHost.frontmost,
        confirmEvery: TimeInterval = 0.1, confirmFor: TimeInterval = 2,
        now: @escaping () -> Date = Date.init
    ) {
        self.enrolled = enrolled
        self.installed = installed
        self.connect = connect
        self.panes = panes
        self.frontmost = frontmost
        self.confirmEvery = confirmEvery
        self.confirmFor = confirmFor
        self.now = now
    }

    nonisolated static func connect(
        home: String, onNotification: @escaping @Sendable (CodexNotification) -> Void, onClose: @escaping @Sendable () -> Void
    ) async -> CodexDaemonClient? {
        let client = CodexDaemonClient(socketPath: CodexDaemonClient.socketPath(home: home), onNotification: onNotification, onClose: onClose)
        do {
            try await client.connect(timeout: callTimeout)
            return client
        } catch {
            return nil
        }
    }

    nonisolated static func panes(surfaces: ResolvedSurfaces) -> Panes {
        let table = AgentProcessTable(surfaces: surfaces)
        let titles = TerminalTitleReader(surfaces: surfaces)
        return { home in
            let wanted = ConnectorFolders.canonical(URL(fileURLWithPath: home)).path
            let found = await Task.detached { table.found(.codex).candidates }.value.filter { candidate in
                candidate.tool.map { CodexInstall.accepts($0) } ?? true
                    && candidate.setup.map { ConnectorFolders.canonical(URL(fileURLWithPath: $0)).path == wanted } == true
            }
            guard !found.isEmpty else { return [] }
            let read = await titles.titles(of: found.map(\.pid))
            return found.compactMap { candidate in read[candidate.pid].map { CodexPane(pid: candidate.pid, title: $0) } }
        }
    }

    static func frontmost() -> (app: AgentHostApp, title: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              let title = ContextProbe.focusedWindowTitle(pid: app.processIdentifier)
        else { return nil }
        let window = ContextProbe.focusedState(pid: app.processIdentifier).windowId
        return (AgentHostApp(bundle: bundle, pid: Int(app.processIdentifier), name: app.localizedName ?? bundle, window: window), title)
    }

    private var folders: [String] {
        var seen: Set<String> = []
        return enrolled().filter { seen.insert($0).inserted }
    }

    var isEnabled: Bool { !folders.isEmpty && installed() }

    var takesImages: Bool { true }

    var queuesInHub: Bool { true }

    func watch(_ changed: @escaping @MainActor (AgentHostChange) -> Void) {
        self.changed = changed
    }

    func unwatch() {
        changed = nil
    }

    func reportsTurns(at location: AgentHostLocation) -> Bool {
        location.host == Self.kind.id && folders.contains(location.instance)
    }

    func scan() async -> AgentHostScan {
        var sessions: [AgentSession] = []
        var titles: [String: String] = [:]
        var problems: [String] = []
        let folders = self.folders
        for folder in folders {
            guard let threads = await list(folder) else {
                problems.append(Self.daemonDown)
                continue
            }
            let shown = await processes(showing: threads.map(\.id), in: folder)
            for thread in threads {
                guard var session = thread.session(instance: folder) else { continue }
                session.pid = shown[thread.id]
                sessions.append(session)
                if let title = thread.title { titles[thread.location(instance: folder).conversationKey] = title }
            }
        }
        if !problems.isEmpty, problems.count == folders.count { return .unreadable(problems[0]) }
        return .found(sessions, titles: titles, problem: problems.first)
    }

    nonisolated static let daemonDown = "Codex\u{2019}s app server isn\u{2019}t running. Start Codex in a terminal to reach its conversations."

    private func processes(showing ids: [String], in folder: String) async -> [String: Int] {
        guard let panes, !ids.isEmpty else { return [:] }
        let home = home(folder)
        let current: [CodexPane]
        if let known = home.panes, now().timeIntervalSince(known.at) < Self.paneLifetime {
            current = known.panes
        } else {
            current = await panes(folder)
            home.panes = (now(), current)
        }
        var shown: [String: Set<Int>] = [:]
        for pane in current {
            guard let id = CodexPaneTitle.thread(in: pane.title, among: ids) else { continue }
            shown[id, default: []].insert(pane.pid)
        }
        return shown.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    private func home(_ folder: String) -> Home {
        if let home = homes[folder] { return home }
        let home = Home()
        homes[folder] = home
        return home
    }

    private func client(_ folder: String) async -> CodexDaemonClient? {
        let home = home(folder)
        if let client = home.client, client.isOpen { return client }
        drop(home)
        let generation = home.generation
        let client = await connect(folder, { [weak self] notification in
            Task { @MainActor [weak self] in self?.apply(notification, in: folder, generation: generation) }
        }, { [weak self] in
            Task { @MainActor [weak self] in self?.closed(folder, generation: generation) }
        })
        guard home.generation == generation, homes[folder] === home else {
            client?.close()
            return nil
        }
        home.client = client
        return client
    }

    private func drop(_ home: Home) {
        home.client?.close()
        home.client = nil
        home.generation += 1
        home.threads = [:]
    }

    private func closed(_ folder: String, generation: Int) {
        guard let home = homes[folder], home.generation == generation else { return }
        drop(home)
        changed?(.listing)
    }

    private func list(_ folder: String) async -> [CodexThread]? {
        guard let client = await client(folder) else { return nil }
        var ids: [String] = []
        var cursor: String?
        for _ in 0..<Self.pageLimit {
            var params: [String: String] = [:]
            if let cursor { params["cursor"] = cursor }
            guard let result = try? await client.call("thread/loaded/list", params, timeout: Self.callTimeout),
                  let page = CodexDaemon.loadedThreads(result)
            else { return nil }
            ids += page.ids
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        var threads: [CodexThread] = []
        for id in ids {
            guard let thread = await read(id, with: client) else { continue }
            threads.append(thread)
        }
        let home = home(folder)
        guard home.client === client else { return nil }
        home.threads = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = Set(threads.map(\.id))
        home.foreignPrompt = home.foreignPrompt.filter { listed.contains($0.key) }
        return threads
    }

    private func read(_ id: String, with client: CodexDaemonClient) async -> CodexThread? {
        struct Params: Encodable, Sendable {
            var threadId: String
            var includeTurns = false
        }
        guard let result = try? await client.call("thread/read", Params(threadId: id), timeout: Self.callTimeout) else { return nil }
        return CodexDaemon.thread(result)
    }

    private func key(_ id: String, in folder: String) -> String {
        AgentHostLocation(host: Self.kind.id, instance: folder, native: id).conversationKey
    }

    private func apply(_ notification: CodexNotification, in folder: String, generation: Int) {
        guard let home = homes[folder], home.generation == generation else { return }
        switch notification {
        case .statusChanged(let id, let status):
            let was = home.threads[id]?.status.liveState
            home.threads[id]?.status = status
            let state = status.liveState
            let asking: Set<AgentLiveState> = [.waitingApproval, .waitingQuestion]
            if let was, asking.contains(was), !(state.map(asking.contains) ?? false) {
                changed?(.event(.waiting(session: key(id, in: folder), prompt: nil)))
            }
            if state == .idle, let was, was != .idle { checkStopped(id, in: folder) }
        case .nameUpdated(let id, let name):
            home.threads[id]?.name = name
        case .started(let thread):
            home.threads[thread.id] = thread
            home.panes = nil
        case .closed(let id):
            home.threads[id] = nil
        case .other:
            return
        }
        changed?(.listing)
    }

    func observe(_ event: AgentEvent) {
        guard let session = event.session else { return }
        for (folder, home) in homes {
            for id in home.threads.keys where key(id, in: folder) == session {
                switch event {
                case .turnStarted(_, _, let prompt):
                    if let prompt, let mine = ownPrompts.firstIndex(of: prompt) {
                        ownPrompts.remove(at: mine)
                    } else {
                        home.foreignPrompt[id] = now()
                        changed?(.event(.typed(session: session)))
                    }
                case .waiting(_, let prompt?) where prompt.said == nil:
                    explain(prompt, thread: id, in: folder)
                default:
                    break
                }
            }
        }
    }

    private func checkStopped(_ id: String, in folder: String) {
        guard let home = homes[folder], let client = home.client else { return }
        let generation = home.generation
        Task { @MainActor [weak self] in
            struct List: Encodable, Sendable {
                var threadId: String
                var limit = 1
            }
            guard let result = try? await client.call("thread/turns/list", List(threadId: id), timeout: Self.callTimeout),
                  CodexDelivery.turns(result)?.turns.first?.status == "interrupted",
                  let self, let home = self.homes[folder], home.generation == generation
            else { return }
            self.changed?(.event(.turnComplete(session: self.key(id, in: folder), reason: "aborted", answer: "")))
        }
    }

    func confirm(request: String, at location: AgentHostLocation) async -> Bool? {
        guard isEnabled, let id = thread(at: location), let client = await client(location.instance) else { return nil }
        struct List: Encodable, Sendable {
            var threadId: String
            var limit = 5
            var itemsView = "full"
        }
        guard let listed = try? await client.call("thread/turns/list", List(threadId: id), timeout: Self.callTimeout),
              let turns = CodexDelivery.turns(listed)?.turns
        else { return nil }
        return CodexDelivery.confirmation(in: turns, clientUserMessageId: Self.messageId(request)) != .absent
    }

    nonisolated static func messageId(_ request: String) -> String { "ks-\(request)" }

    private func explain(_ prompt: AgentPrompt, thread id: String, in folder: String) {
        guard let home = homes[folder], let client = home.client else { return }
        let generation = home.generation
        Task { @MainActor [weak self] in
            struct List: Encodable, Sendable {
                var threadId: String
                var limit = 1
                var itemsView = "full"
            }
            guard let result = try? await client.call("thread/turns/list", List(threadId: id), timeout: Self.callTimeout),
                  let said = CodexDelivery.lastAgentWords(result), let self, let home = self.homes[folder], home.generation == generation,
                  let state = home.threads[id]?.status.liveState, [.waitingApproval, .waitingQuestion].contains(state)
            else { return }
            var explained = prompt
            explained.said = said
            self.changed?(.event(.waiting(session: self.key(id, in: folder), prompt: explained)))
        }
    }

    func front(among locations: [AgentHostLocation], reported: AgentHostLocation?, in app: AgentHostApp?) async -> AgentHostFront {
        guard let (app, title) = frontmost() else { return .unknown }
        let ours = locations.filter { $0.host == Self.kind.id }
        guard let id = CodexPaneTitle.thread(in: title, among: ours.map(\.native)),
              let shown = ours.first(where: { $0.native == id })
        else { return .unknown }
        return .shown(shown, in: app)
    }

    func rename(_ location: AgentHostLocation, to name: String) async -> Bool {
        guard isEnabled, let id = thread(at: location), let client = await client(location.instance) else { return false }
        return (try? await client.call("thread/name/set", ["threadId": id, "name": name], timeout: Self.callTimeout)) != nil
    }

    func deliver(_ text: String, images: [String], request: String, to location: AgentHostLocation) async -> AgentHostDelivery {
        guard isEnabled, let id = thread(at: location) else { return .refused("Codex no longer lists this conversation.") }
        guard let client = await client(location.instance) else { return .refused(Self.daemonDown) }
        let home = home(location.instance)
        if home.threads[id] == nil, let thread = await read(id, with: client), home.client === client { home.threads[id] = thread }
        let status = home.threads[id]?.status
        switch CodexDelivery.precheck(status: status, lastForeignPrompt: home.foreignPrompt[id], now: now()) {
        case .refuse:
            return .refused("Codex no longer has this conversation open.")
        case .hold:
            return .queued
        case .send:
            return await send(text, images: images, request: request, thread: id, home: home, client: client)
        }
    }

    private struct Input: Encodable, Sendable {
        var type: String
        var text: String?
        var text_elements: [String]?
        var path: String?

        static func of(_ text: String, images: [String]) -> [Input] {
            [Input(type: "text", text: text, text_elements: [])] + images.map { Input(type: "localImage", path: $0) }
        }
    }

    private func send(
        _ text: String, images: [String], request: String, thread id: String, home: Home, client: CodexDaemonClient
    ) async -> AgentHostDelivery {
        let messageId = Self.messageId(request)
        remember(AgentPromptDigest.of(text))
        if case .active = home.threads[id]?.status {
            if let steered = await steer(text, images: images, messageId: messageId, thread: id, client: client) { return steered }
            guard let fresh = await read(id, with: client), home.client === client else { return .uncertain }
            home.threads[id] = fresh
            guard fresh.status == .idle else { return .uncertain }
        }
        struct Params: Encodable, Sendable {
            var threadId: String
            var clientUserMessageId: String
            var input: [Input]
        }
        let result: Data
        do {
            result = try await client.call(
                "turn/start", Params(threadId: id, clientUserMessageId: messageId, input: Input.of(text, images: images)), timeout: Self.callTimeout)
        } catch CodexDaemonClient.Failure.rejected {
            return .refused("Codex did not take the message.")
        } catch {
            return .uncertain
        }
        guard CodexDelivery.startedTurn(result) != nil else { return .uncertain }
        return await confirm(messageId, thread: id, client: client)
    }

    private func steer(_ text: String, images: [String], messageId: String, thread id: String, client: CodexDaemonClient) async -> AgentHostDelivery? {
        struct List: Encodable, Sendable {
            var threadId: String
            var limit = 1
        }
        guard let listed = try? await client.call("thread/turns/list", List(threadId: id), timeout: Self.callTimeout),
              let running = CodexDelivery.turns(listed)?.turns.first(where: { $0.status == "inProgress" })
        else { return nil }
        struct Params: Encodable, Sendable {
            var threadId: String
            var expectedTurnId: String
            var clientUserMessageId: String
            var input: [Input]
        }
        do {
            _ = try await client.call(
                "turn/steer", Params(threadId: id, expectedTurnId: running.id, clientUserMessageId: messageId, input: Input.of(text, images: images)),
                timeout: Self.callTimeout)
        } catch CodexDaemonClient.Failure.rejected {
            return nil
        } catch {
            return .uncertain
        }
        return await confirm(messageId, thread: id, client: client)
    }

    private func confirm(_ messageId: String, thread id: String, client: CodexDaemonClient) async -> AgentHostDelivery {
        struct List: Encodable, Sendable {
            var threadId: String
            var limit = 2
            var itemsView = "full"
        }
        let deadline = Date().addingTimeInterval(confirmFor)
        while true {
            guard let listed = try? await client.call("thread/turns/list", List(threadId: id), timeout: Self.callTimeout),
                  let turns = CodexDelivery.turns(listed)?.turns
            else { return .uncertain }
            if CodexDelivery.confirmation(in: turns, clientUserMessageId: messageId) != .absent { return .accepted }
            guard Date() < deadline else { return .uncertain }
            try? await Task.sleep(for: .seconds(confirmEvery))
        }
    }

    private func remember(_ digest: String) {
        ownPrompts.append(digest)
        if ownPrompts.count > Self.ownPromptMemory { ownPrompts.removeFirst() }
    }

    private func thread(at location: AgentHostLocation) -> String? {
        guard location.host == Self.kind.id, folders.contains(location.instance), !location.native.isEmpty else { return nil }
        return location.native
    }
}
