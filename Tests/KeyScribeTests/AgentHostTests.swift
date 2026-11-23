import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct AgentHostTests {
    typealias FakeTransport = AgentHubTests.FakeTransport
    typealias FakeDiscovery = AgentHubTests.FakeDiscovery
    typealias FakeFocus = AgentHubTests.FakeFocus
    typealias FakeFront = AgentHubTests.FakeFront

    static let kind = AgentKind(id: "example", displayName: "Example", connectorName: "Example plugin")

    final class FakeHost: AgentHost {
        var isEnabled = true
        var takesImages = true
        var conversations: [AgentSession] = []
        var titles: [String: String] = [:]
        var workspaces: [String: String] = [:]
        var shownInstead: [String: String] = [:]
        var carried: Set<AgentHostLocation> = []
        var problem: String?
        var answers = true
        var hangs = false
        var opening = AgentHostOpen.opened
        var front = AgentHostFront.unknown
        var identityKeys = ["EXAMPLE_THREAD"]
        var delivery = AgentHostDelivery.accepted
        var route = AgentHostDeliveryRoute.host
        var reportsDeliveredTurns = false
        func deliveryRoute(at location: AgentHostLocation) -> AgentHostDeliveryRoute { route }
        private(set) var retitled: [(AgentHostLocation, String)] = []
        private(set) var scans = 0
        private(set) var opened: [AgentHostLocation] = []
        private(set) var asked: [[AgentHostLocation]] = []
        private(set) var reported: [AgentHostLocation?] = []
        private(set) var delivered: [(String, String, AgentHostLocation)] = []
        private(set) var deliveredImages: [[String]] = []
        private(set) var openSawCancelled = false
        private(set) var openSawWanted: [Bool] = []

        var calls: Int { scans + opened.count + asked.count + delivered.count }

        var gated = false
        private var gate: [CheckedContinuation<Void, Never>] = []

        func passOne() {
            guard !gate.isEmpty else { return }
            gate.removeFirst().resume()
        }

        func openGate() {
            gated = false
            gate.forEach { $0.resume() }
            gate = []
        }

        private func stall() async {
            guard hangs else { return }
            try? await Task.sleep(for: .seconds(30))
        }

        func scan() async -> AgentHostScan {
            scans += 1
            await scanGate.pass()
            return answers
                ? .found(conversations, titles: titles, shownInstead: shownInstead, carried: carried, problem: problem, workspaces: workspaces) : .unreadable("not running")
        }

        func open(_ location: AgentHostLocation, stillWanted: @escaping @MainActor () -> Bool) async -> AgentHostOpen {
            opened.append(location)
            await stall()
            openSawCancelled = Task.isCancelled
            openSawWanted.append(stillWanted())
            return opening
        }

        func location(in environment: [String: String]) -> AgentHostLocation? {
            environment["EXAMPLE_THREAD"].map { AgentHostTests.location($0) }
        }

        var window: AgentHostApp?
        private(set) var windowReads = 0

        func focusedWindow() -> AgentHostApp? {
            windowReads += 1
            return window
        }

        var copy: AgentHostCopy?

        func copyInFront() -> AgentHostCopy? { copy }

        private(set) var unwatched = 0

        func unwatch() { unwatched += 1 }

        func front(among locations: [AgentHostLocation], reported: AgentHostLocation?, in app: AgentHostApp?) async -> AgentHostFront {
            asked.append(locations)
            self.reported.append(reported)
            await stall()
            return front
        }

        let renameGate = Gate()
        let scanGate = Gate()
        var renames = true
        private(set) var renaming = 0
        private(set) var mostRenaming = 0

        func rename(_ location: AgentHostLocation, to name: String) async -> Bool {
            renaming += 1
            mostRenaming = max(mostRenaming, renaming)
            defer { renaming -= 1 }
            await renameGate.pass()
            retitled.append((location, name))
            return renames
        }

        var whileDelivering: (@MainActor () -> Void)?
        var reportsTurns = false
        private(set) var observed: [AgentEvent] = []

        var onObserve: (@MainActor (AgentEvent) -> Void)?
        func observe(_ event: AgentEvent) {
            observed.append(event)
            onObserve?(event)
        }

        func reportsTurns(at location: AgentHostLocation) -> Bool { reportsTurns }

        private(set) var watcher: (@MainActor (AgentHostChange) -> Void)?

        func watch(_ changed: @escaping @MainActor (AgentHostChange) -> Void) { watcher = changed }

        var queuesInHub = false
        var replies: [AgentHostDelivery] = []
        var confirmation: Bool?
        private(set) var confirmed: [String] = []

        func confirm(request: String, at location: AgentHostLocation) async -> Bool? {
            confirmed.append(request)
            return confirmation
        }

        var record: [String: [String]] = [:]
        var recordStalls = false
        let recordCancelled = Signal("stalled turn record cancelled")
        func taken(in turn: String, at location: AgentHostLocation) async -> [String]? {
            if recordStalls {
                do { try await Task.sleep(for: .seconds(30)) } catch { recordCancelled.fire() }
            }
            return record[turn]
        }

        func deliver(_ text: String, images: [String], request: String, to location: AgentHostLocation) async -> AgentHostDelivery {
            delivered.append((text, request, location))
            deliveredImages.append(images)
            whileDelivering?()
            if gated { await withCheckedContinuation { gate.append($0) } }
            await stall()
            return replies.isEmpty ? delivery : replies.removeFirst()
        }
    }

    static let instance = "http://127.0.0.1:9"

    static func location(_ native: String, instance: String = instance) -> AgentHostLocation {
        AgentHostLocation(host: "example", instance: instance, native: native)
    }

    static func id(_ native: String, instance: String = instance) -> String {
        AgentSessionID.make(agent: "example", native: location(native, instance: instance).conversationKey)
    }

    static func thread(_ native: String, cwd: String = "/src/docs", instance: String = instance, startedAt: Int? = nil, pid: Int? = nil) -> AgentSession {
        AgentSession(
            agent: "example", id: native, pid: pid, cwd: cwd, state: .idle, startedAt: startedAt, host: location(native, instance: instance))
    }

    @MainActor final class Gate {
        var closed = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var waiting: Int { waiters.count }

        func pass() async {
            guard closed else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            closed = false
            let released = waiters
            waiters = []
            released.forEach { $0.resume() }
        }
    }

    private func makeHub(
        _ host: FakeHost, transport: FakeTransport = FakeTransport(), focus: FakeFocus? = nil, front: FakeFront? = nil,
        names: AgentNameStore? = nil, places: (any AgentPlaceReading)? = nil, allowed: @escaping @MainActor (String) -> Bool = { _ in true }, hostDeadline: Duration = .milliseconds(50),
        claude: FakeDiscovery = FakeDiscovery(kind: .claude), environments: [Int: [String: String]] = [:], handOffLimit: Duration = .seconds(30),
        parents: [Int: Int] = [:], now: @escaping () -> Date = Date.init, accessibility: @escaping @MainActor () -> Bool = { true },
        hostConfirmDelay: Duration = .seconds(3), receiptTimeout: Duration = .milliseconds(50),
        heldLimit: Duration = .milliseconds(100)
    ) -> AgentHub {
        transport.sessionsOf = { instance in
            if instance.hasPrefix("plugin/") { return [Self.id(String(instance.dropFirst("plugin/".count)))] }
            return instance == "i1" ? transport.live.filter { $0.hasPrefix("claude:") } + [Self.id("t1")] : []
        }
        return AgentHub(
            transport: transport, discovery: [claude], names: names, focus: focus, front: front,
            receiptTimeout: receiptTimeout, handOffLimit: handOffLimit, scanDeadline: .seconds(30), places: places,
            hosts: [AgentHostIntegration(kind: Self.kind, make: { host })], hostAllowed: allowed, hostDeadline: hostDeadline, hostOpenDeadline: hostDeadline,
            hostConfirmDelay: hostConfirmDelay, heldLimit: heldLimit,
            processEnvironment: { pid, keys in (environments[pid] ?? [:]).filter { keys.contains($0.key) } },
            processParent: { parents[$0] }, now: now,
            makeId: { "r1" }, accessibilityTrusted: accessibility)
    }

    @Test func aHostedConversationNeverLeavesConversationNamesUnread() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let reader = AgentPlaceTrackerTests.Reader()
        let hub = makeHub(host, places: reader)
        await hub.rescan()
        for _ in 0..<50 {
            if let reading = hub.placeTracker?.reading { await reading.value } else { await Task.yield() }
        }
        #expect(hub.directory.conversations.map(\.id).contains(Self.id("t1")))
        #expect(!hub.placesUnread(hub.directory.conversations.map(\.id)))
    }

    @Test func aHostedTerminalConversationCanUseThePlaceOfItsOwnProcess() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1", pid: 99)]
        host.titles = ["t1": "release notes"]
        let reader = AgentPlaceTrackerTests.Reader()
        reader.answers = [Self.id("t1"): .found(AgentPlace(surface: "Terminal", labels: [
            .init(text: "launcher", level: .pane, container: "pane1"),
        ], containers: ["pane1"]))]
        let hub = makeHub(host, places: reader)
        await hub.rescan()
        while let reading = hub.placeTracker?.reading { await reading.value }
        #expect(reader.asked.flatMap { $0 }.contains(Self.id("t1")))
        #expect(hub.names == ["launcher": Self.id("t1")])
        #expect(!hub.placesUnread([Self.id("t1")]))
        hub.stop()
    }

    @Test func aHostedConversationNeverKeepsPlacesBeingReadAgain() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let claude = FakeDiscovery(kind: .claude)
        claude.result = .found([Self.claudeSession()])
        let reader = AgentPlaceTrackerTests.Reader()
        let hub = makeHub(host, places: reader, claude: claude)
        await hub.rescan()
        for _ in 0..<50 {
            if let reading = hub.placeTracker?.reading { await reading.value } else { await Task.yield() }
        }
        let settled = reader.reads
        for _ in 0..<5 { hub.refresh() }
        for _ in 0..<50 {
            if let reading = hub.placeTracker?.reading { await reading.value } else { await Task.yield() }
        }
        #expect(hub.directory.conversations.map(\.id).contains(Self.id("t1")))
        #expect(settled > 0)
        #expect(reader.reads == settled)
    }

    @Test func conversationsOfAnInstanceTheHostCouldNotReadStayListedAsLastSeenWithItsProblem() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1"), Self.thread("t2", instance: "/other")]
        host.titles = [Self.location("t2", instance: "/other").conversationKey: "release notes"]
        host.carried = [Self.location("t2", instance: "/other")]
        host.problem = "Other isn\u{2019}t open."
        let hub = makeHub(host)
        await hub.rescan()
        #expect(Set(hub.directory.conversations.map(\.id)) == [Self.id("t1"), Self.id("t2", instance: "/other")])
        #expect(hub.lastSeen == [Self.id("t2", instance: "/other")])
        #expect(hub.discoveryProblems["example"] == "Other isn\u{2019}t open.")
        #expect(hub.names["release notes"] == Self.id("t2", instance: "/other"))
    }

    @Test func aHostIsCalledOnlyWhileTheUserHasItTurnedOn() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        var turnedOn: Set<String> = []
        let hub = makeHub(host, allowed: { turnedOn.contains($0) })
        await hub.rescan()
        #expect(hub.directory.conversations.isEmpty)
        #expect(await hub.sessionInFront() == nil)
        #expect(await hub.open(Self.id("t1")) == .none)
        #expect(host.calls == 0)
        turnedOn = ["example"]
        await hub.rescan()
        #expect(hub.directory.conversations.map(\.id) == [Self.id("t1")])
        turnedOn = []
        #expect(await hub.deliver("hi", to: Self.id("t1")) != .sent("docs"))
        await hub.rescan()
        #expect(hub.directory.conversations.isEmpty)
        #expect(host.calls == 1)
    }

    @Test func aHostWhoseToolIsNotInstalledIsNeverCalledListsNothingAndSaysSoOnlyWhileTurnedOn() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        var turnedOn = true
        let hub = makeHub(host, allowed: { _ in turnedOn })
        await hub.rescan()
        #expect(hub.directory.conversations.map(\.id) == [Self.id("t1")])
        host.isEnabled = false
        let calls = host.calls
        await hub.rescan()
        #expect(hub.directory.conversations.isEmpty)
        #expect(await hub.sessionInFront() == nil)
        #expect(await hub.open(Self.id("t1")) == .none)
        #expect(host.calls == calls)
        #expect(hub.discoveryProblems["example"] == "Example isn\u{2019}t installed on this Mac. Install it, or turn this off.")
        turnedOn = false
        await hub.rescan()
        #expect(hub.discoveryProblems["example"] == nil)
    }

    @Test func aHostedConversationIsListedReadyWithoutAProcessAndOpenedThroughItsHost() async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let focus = FakeFocus()
        let hub = makeHub(host, focus: focus)
        await hub.rescan()
        let listed = try #require(hub.directory.conversations.first)
        #expect(listed.id == Self.id("t1"))
        #expect(listed.pid == nil)
        #expect(listed.handle == "docs")
        #expect(AgentRoster.stateLabel(listed) == "Ready")
        #expect(AgentRoster.isAvailable(listed))
        #expect(await hub.open(Self.id("t1")) == .exact)
        #expect(host.opened == [Self.location("t1")])
        host.opening = .requested
        #expect(await hub.open(Self.id("t1")) == .requested("Example"))
        host.opening = .failed
        #expect(await hub.open(Self.id("t1")) == .none)
        host.opening = .unsupported
        #expect(await hub.open(Self.id("t1")) == .none)
        host.opening = .refused("Example has no window open to show this thread.")
        #expect(await hub.open(Self.id("t1")) == .refused("Example has no window open to show this thread."))
        #expect(await hub.open(Self.id("t1"), stillWanted: { false }) == .none)
        #expect(focus.focused.isEmpty)
        let result = AgentFocusResult.refused("Example has no window open to show this thread.")
        #expect(result.historySummary(handle: "docs") == "Couldn\u{2019}t open docs. Example has no window open to show this thread.")
    }

    @Test func openAskedAfterItIsNoLongerWantedNeverReachesTheHost() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        #expect(await hub.open(Self.id("t1"), stillWanted: { false }) == .none)
        #expect(host.opened.isEmpty)
    }

    @Test func theHostSaysWhichOfItsConversationsIsInFrontWhenNoTerminalShowsOne() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1"), Self.thread("t2", cwd: "/src/site")]
        let front = FakeFront()
        let hub = makeHub(host, front: front)
        await hub.rescan()
        let app = AgentHostApp(bundle: "dev.example.app", pid: 50, name: "Example")
        host.front = .shown(Self.location("t2"), in: app)
        #expect(await hub.sessionInFront() == FrontSession(id: Self.id("t2"), app: FrontApp(bundle: "dev.example.app", pid: 50, name: "Example")))
        #expect(host.asked.last?.map(\.native).sorted() == ["t1", "t2"])
        host.front = .shown(Self.location("t2"), in: AgentHostApp(bundle: "dev.example.app", pid: 50, name: "Example", window: "cg:7"))
        #expect(await hub.sessionInFront()?.app.window == "cg:7")
        host.front = .unknown
        #expect(await hub.sessionInFront() == nil)
        let terminal = FrontSession(id: "claude:s1", app: FrontApp(bundle: "com.mitchellh.ghostty", pid: 9, name: "Ghostty"))
        front.answer = terminal
        let asked = host.asked.count
        #expect(await hub.sessionInFront() == terminal)
        #expect(host.asked.count == asked)
    }

    @Test func whetherAHostedConversationIsInFrontIsAskedOfItsHostAloneAndATerminalConversationIsNotItsToAnswer() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1"), Self.thread("t2", cwd: "/src/site")]
        let front = FakeFront()
        let hub = makeHub(host, front: front)
        await hub.rescan()
        host.front = .shown(Self.location("t2"), in: AgentHostApp(bundle: "dev.example.app", pid: 50, name: "Example"))
        #expect(await hub.hostShows(Self.id("t2")) == true)
        #expect(await hub.hostShows(Self.id("t1")) == false)
        #expect(front.asked.isEmpty)
        host.front = .unknown
        #expect(await hub.hostShows(Self.id("t2")) == false)
        #expect(await hub.hostShows("claude:s1") == nil)
    }

    @Test func aHostedConversationRunningInATerminalCountsAsInFrontWhenThatTerminalShowsItThoughItsHostSeesNothing() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1", pid: 70), Self.thread("t2", cwd: "/src/site")]
        let front = FakeFront()
        let hub = makeHub(host, front: front)
        await hub.rescan()
        host.front = .unknown
        front.answer = FrontSession(id: Self.id("t1"), app: FrontApp(bundle: "com.mitchellh.ghostty", pid: 9, name: "Ghostty"))
        #expect(await hub.showsInFront(Self.id("t1"), glancing: front))
        #expect(await !hub.showsInFront(Self.id("t2"), glancing: front))
        front.answer = nil
        #expect(await !hub.showsInFront(Self.id("t1"), glancing: front))
        host.front = .shown(Self.location("t2"), in: AgentHostApp(bundle: "dev.example.app", pid: 50, name: "Example"))
        #expect(await hub.showsInFront(Self.id("t2"), glancing: front))
    }

    @Test func aHostThatSaysItsConversationIsInFrontIsBelievedWithoutWaitingForASlowTerminalRead() async {
        final class StuckFront: AgentFronting, @unchecked Sendable {
            func shown(among agents: [AgentFrontCandidate], asking: @escaping @MainActor @Sendable (String) -> Void) async -> FrontSession? {
                try? await Task.sleep(for: .seconds(30))
                return nil
            }
        }
        let host = FakeHost()
        host.conversations = [Self.thread("t1", pid: 70)]
        let hub = makeHub(host)
        await hub.rescan()
        host.front = .shown(Self.location("t1"), in: AgentHostApp(bundle: "dev.example.app", pid: 50, name: "Example"))
        let started = Date()
        #expect(await hub.showsInFront(Self.id("t1"), glancing: StuckFront()))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func theHostIsToldWhichConversationItsOwnConnectorLastSaidItsWindowShowsWhileThatConnectorIsLive() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1"), Self.thread("t2", cwd: "/src/site")]
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        _ = await hub.sessionInFront()
        #expect(host.reported.last == .some(nil))
        transport.live = [Self.id("t1"), Self.id("t2")]
        hub.handle(.shown(session: Self.id("t1"), on: true))
        _ = await hub.sessionInFront()
        #expect(host.reported.last == Self.location("t1"))
        hub.handle(.shown(session: Self.id("t2"), on: true))
        _ = await hub.sessionInFront()
        #expect(host.reported.last == Self.location("t2"))
        transport.live = [Self.id("t1")]
        _ = await hub.sessionInFront()
        #expect(host.reported.last == .some(nil))
        transport.live = [Self.id("t1"), Self.id("t2")]
        hub.handle(.shown(session: Self.id("t1"), on: false))
        _ = await hub.sessionInFront()
        #expect(host.reported.last == .some(nil))
        hub.handle(.shown(session: Self.id("t2"), on: true))
        hub.handle(.shown(session: "claude:s9", on: false))
        _ = await hub.sessionInFront()
        #expect(host.reported.last == Self.location("t2"))
    }

    @Test func disconnectingTheOnlyConversationShownForgetsItAndALaterReportForItIsIgnored() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport, names: AgentNameStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ks-shown-\(UUID().uuidString)")))
        await hub.rescan()
        transport.live = [Self.id("t1")]
        hub.handle(.shown(session: Self.id("t1"), on: true))
        _ = await hub.sessionInFront()
        #expect(host.reported.last == Self.location("t1"))
        hub.disconnect(Self.id("t1"))
        _ = await hub.sessionInFront()
        #expect(host.reported.last == .some(nil))
        hub.handle(.shown(session: Self.id("t1"), on: true))
        _ = await hub.sessionInFront()
        #expect(host.reported.last == .some(nil))
        hub.reconnect(Self.id("t1"))
        _ = await hub.sessionInFront()
        #expect(host.reported.last == .some(nil))
        hub.handle(.shown(session: Self.id("t1"), on: true))
        _ = await hub.sessionInFront()
        #expect(host.reported.last == Self.location("t1"))
    }

    @Test(arguments: [
        (AgentHostDelivery.accepted, AgentReceipt.sent("docs")),
        (.queued, .queued("docs")),
        (.uncertain, .uncertain("docs")),
        (.refused("thread is archived"), .notSent("docs", reason: .hostRefused("thread is archived"))),
        (.unsupported, .notSent("docs", reason: .hostTakesNoMessages("Example"))),
    ])
    func dictationToAHostedConversationGoesThroughItsHostOnceAndSaysOnlyWhatTheHostProved(answer: AgentHostDelivery, receipt: AgentReceipt) async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        host.delivery = answer
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        #expect(await hub.deliver("fix the test", to: Self.id("t1"), request: "q1") == receipt)
        #expect(host.delivered.map(\.0) == ["fix the test"])
        #expect(host.delivered.map(\.1) == ["q1"])
        #expect(transport.sent.allSatisfy { if case .status = $0.0 { true } else { false } })
    }

    private func connected(_ host: FakeHost, _ transport: FakeTransport, features: [String], receiptTimeout: Duration = .seconds(5)) async -> AgentHub {
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host, transport: transport, receiptTimeout: receiptTimeout)
        await hub.rescan()
        var hello = Self.hello(Self.id("t1"), features: features)
        hello.agent = "example"
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(hello))
        await hub.rescan()
        return hub
    }

    private func submitted(_ transport: FakeTransport) async -> (id: String, text: String)? {
        for _ in 0..<400 {
            for (command, session) in transport.sent where session == Self.id("t1") {
                if case .submit(let id, _, let text, _, _, _, _, _) = command { return (id, text) }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    @Test func aHostWhoseConnectorDeliversSendsOverTheBridgeAndFollowsTheReply() async throws {
        let host = FakeHost()
        host.route = .connector
        let transport = FakeTransport()
        let hub = await connected(host, transport, features: ["promptDigest", "readiness", "notify", "steer"])
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        let delivery = Task { await hub.deliver("fix the test", to: Self.id("t1"), request: "q1") }
        let sent = try #require(await submitted(transport))
        #expect(sent.text == "fix the test")
        hub.handle(.submitted(request: sent.id, turn: "t-1"))
        #expect(await delivery.value == .sent("docs"))
        #expect(host.delivered.isEmpty)
        let prompt = AgentPromptDigest.of("fix the test")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "t-1", prompt: prompt))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "Fixed the flaky test.", after: AgentTurnInput(from: nil, prompt: prompt)))
        #expect(origins == ["q1"])
    }

    @Test func aMessageHeldForAnApprovalInAConversationItsConnectorDeliversIsReleasedThroughTheConnector() async throws {
        let host = FakeHost()
        host.route = .connector
        host.queuesInHub = true
        let transport = FakeTransport()
        let hub = await connected(host, transport, features: ["promptDigest", "readiness", "notify", "steer"])
        hub.handle(.waiting(session: Self.id("t1"), prompt: AgentPrompt(kind: "confirm", title: "Run it?")))
        await hub.rescan(rereadingTitles: false)
        guard case .queued = await hub.deliver("also run lint", to: Self.id("t1"), request: "q1") else {
            Issue.record("a message for a conversation waiting on an approval is held")
            return
        }
        hub.handle(.waiting(session: Self.id("t1"), prompt: nil))
        await hub.rescan(rereadingTitles: false)
        let sent = try #require(await submitted(transport))
        #expect(sent.text == "also run lint")
        #expect(host.delivered.isEmpty)
    }

    @Test func aMessageHeldForAHostThatIsTurnedOffIsNeverHandedToAConnector() async throws {
        let host = FakeHost()
        host.queuesInHub = true
        let transport = FakeTransport()
        let hub = await connected(host, transport, features: ["promptDigest", "readiness", "notify", "steer"])
        hub.handle(.waiting(session: Self.id("t1"), prompt: AgentPrompt(kind: "confirm", title: "Run it?")))
        await hub.rescan(rereadingTitles: false)
        guard case .queued = await hub.deliver("also run lint", to: Self.id("t1"), request: "q1") else {
            Issue.record("a message for a conversation waiting on an approval is held")
            return
        }
        host.isEnabled = false
        hub.handle(.waiting(session: Self.id("t1"), prompt: nil))
        host.watcher?(.state(Self.location("t1"), .idle))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!transport.sent.contains { if case .submit = $0.0 { true } else { false } })
        #expect(host.delivered.isEmpty)
    }

    @Test func aHostThatDeliversButCannotSaysSoAndNeverFallsThroughToAConnector() async {
        let host = FakeHost()
        host.delivery = .unsupported
        let transport = FakeTransport()
        let hub = await connected(host, transport, features: ["promptDigest", "readiness", "steer"])
        #expect(await hub.deliver("fix the test", to: Self.id("t1"), request: "q1") == .notSent("docs", reason: .hostTakesNoMessages("Example")))
        #expect(!transport.sent.contains { if case .submit = $0.0 { true } else { false } })
    }

    @Test func aConversationItsConnectorDeliversTakesImagesOnlyWhenTheConnectorSaysSo() async {
        let host = FakeHost()
        host.route = .connector
        host.takesImages = true
        let transport = FakeTransport()
        let plain = await connected(host, transport, features: ["promptDigest"])
        #expect(!plain.takesImages(Self.id("t1")))
        let announcing = FakeHost()
        announcing.route = .connector
        let withImages = await connected(announcing, FakeTransport(), features: ["promptDigest", "images"])
        #expect(withImages.takesImages(Self.id("t1")))
    }

    @Test func aReplyIsFollowedByTheRequestTheHostSaysStartedTheTurnWithoutAPrompt() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        host.reportsTurns = true
        let hub = makeHub(host)
        await hub.rescan()
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        host.whileDelivering = { host.watcher?(.delivered(request: "q1", at: Self.location("t1"), turn: "turn-1")) }
        #expect(await hub.deliver("fix the test", to: Self.id("t1"), request: "q1") == .sent("docs"))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "Fixed the flaky test.", after: nil, turn: "turn-1"))
        #expect(origins == ["q1"])
    }

    @Test func aReplyIsFollowedByRequestEvenWhenTheTurnReportsDifferentText() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        host.reportsTurns = true
        let hub = makeHub(host)
        await hub.rescan()
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        host.whileDelivering = { host.watcher?(.delivered(request: "q2", at: Self.location("t1"), turn: "turn-2")) }
        _ = await hub.deliver("and the logout too", to: Self.id("t1"), request: "q2")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-2", prompt: AgentPromptDigest.of("fix the login and the logout too")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "Both fixed.", after: nil, turn: "turn-2"))
        #expect(origins == ["q2"])
    }

    private func accepting(_ host: FakeHost, clock: AgentHubTests.Clock = AgentHubTests.Clock()) async -> (AgentHub, FakeTransport) {
        host.conversations = [Self.thread("t1")]
        host.reportsTurns = true
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport, now: { clock.now })
        await hub.rescan()
        transport.live.insert(Self.id("t1"))
        transport.liveInstances.insert(Self.pluginInstance)
        hub.handle(.hello(Self.pluginHello(Self.id("t1"), features: ["promptDigest", "merge", "accepted"])))
        await hub.rescan()
        return (hub, transport)
    }

    private func ended(
        _ hub: AgentHub, _ answer: String, took accepted: [String]?, at: Date? = nil, prompt: String? = nil, from: AgentTurnInput.Sender? = nil
    ) {
        hub.handle(.turnComplete(
            session: Self.id("t1"), reason: "complete", answer: answer,
            after: AgentTurnInput(
                from: from, prompt: prompt.map(AgentPromptDigest.of),
                accepted: accepted?.map { AgentAcceptedMessage(digest: AgentPromptDigest.of($0), at: at) })))
    }

    @Test(arguments: Digest.allCases, [false, true])
    func aTurnReadsItsReplyOnceForTheLastDictationItsHostSaysItTookHoweverItsStartWasReported(start: Digest, steered: Bool) async {
        let (hub, _) = await accepting(FakeHost())
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        _ = await hub.deliver("reply with one", to: Self.id("t1"), request: "q1")
        let prompt: String? = switch start {
        case .right: AgentPromptDigest.of("reply with one")
        case .wrong: AgentPromptDigest.of("something typed in bb")
        case .absent: nil
        }
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: prompt))
        var accepted = ["reply with one"]
        if steered {
            _ = await hub.deliver("also reply with two", to: Self.id("t1"), request: "q2")
            accepted.append("also reply with two")
        }
        ended(hub, "One. Two.", took: accepted)
        #expect(origins == [steered ? "q2" : "q1"])
    }

    enum Between: Sendable, CaseIterable {
        case nothing, anotherTurnTheAgentStarted, turnsTheAgentKeptStartingPastTheWindow, aTypedMessage, anotherAgentsMessage, aTurnWithoutItsRecord, aLongPause
    }

    nonisolated static let continuationGrid: [(Bool, Between, AgentTurnInput.Sender?)] = [false, true].flatMap { steered in
        Between.allCases.flatMap { between in [nil, AgentTurnInput.Sender.task].map { (steered, between, $0) } }
    }

    @Test(arguments: continuationGrid)
    func aTurnTheAgentStartsWithoutAMessageIsReadForTheDictationItsLastDictatedTurnTookUntilAnotherMessageOrTheWindowFromThatTurn(
        steered: Bool, between: Between, from: AgentTurnInput.Sender?
    ) async {
        let clock = AgentHubTests.Clock()
        let (hub, _) = await accepting(FakeHost(), clock: clock)
        var read: [(String?, String, SpokenResult.Cause?)] = []
        hub.onResult = { _, _, answer, _, origin, cause in read.append((origin, answer, cause)) }
        _ = await hub.deliver("say the word one", to: Self.id("t1"), request: "q1")
        let sent = clock.now
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: AgentPromptDigest.of("say the word one")))
        var accepted = ["say the word one"]
        if steered {
            _ = await hub.deliver("say the word two", to: Self.id("t1"), request: "q2")
            accepted.append("say the word two")
        }
        ended(hub, "One.", took: accepted, at: sent)
        let last = steered ? "q2" : "q1"
        var expected: [(String?, String)] = [(last, "One.")]
        let gap = AgentHub.continuationWindow * 0.4
        if between != .nothing {
            clock.now += gap
            hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-2", prompt: nil))
        }
        switch between {
        case .nothing: break
        case .anotherTurnTheAgentStarted:
            ended(hub, "Still working.", took: [], from: from)
            expected.append((last, "Still working."))
        case .turnsTheAgentKeptStartingPastTheWindow:
            ended(hub, "Still working.", took: [], from: from)
            clock.now += gap
            hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-2b", prompt: nil))
            ended(hub, "Almost.", took: [], from: from)
            expected += [(last, "Still working."), (last, "Almost.")]
        case .aTypedMessage: ended(hub, "Typed answer.", took: ["something typed in bb"], at: clock.now)
        case .anotherAgentsMessage: ended(hub, "Child answer.", took: ["a child thread finished"], at: clock.now, from: .agent)
        case .aTurnWithoutItsRecord: ended(hub, "Unknown.", took: nil)
        case .aLongPause: clock.now += AgentHub.continuationWindow
        }
        clock.now += gap
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-3", prompt: nil))
        ended(hub, "Two.", took: [], from: from)
        if between == .nothing || between == .anotherTurnTheAgentStarted { expected.append((last, "Two.")) }
        #expect(read.map(\.0) == expected.map(\.0))
        #expect(read.map(\.1) == expected.map(\.1))
        #expect(read.dropFirst().allSatisfy { $0.2 == from.map(SpokenResult.Cause.sender) })
    }

    @Test func twoDictationsWithTheSameTextAreEachReadForTheTurnThatTookThem() async {
        let (hub, _) = await accepting(FakeHost())
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        _ = await hub.deliver("continue", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: AgentPromptDigest.of("continue")))
        _ = await hub.deliver("continue", to: Self.id("t1"), request: "q2")
        ended(hub, "First.", took: ["continue"])
        #expect(origins == ["q1"])
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-2", prompt: AgentPromptDigest.of("continue")))
        ended(hub, "Second.", took: ["continue"])
        #expect(origins == ["q1", "q2"])
    }

    enum Twin: Sendable, CaseIterable { case typedBeforeTheDictation, sentAfterTheTurnEnded }

    @Test(arguments: Twin.allCases)
    func theSameWordsTypedInTheHostNeverTakeADictationsReply(twin: Twin) async {
        let clock = AgentHubTests.Clock()
        let (hub, _) = await accepting(FakeHost(), clock: clock)
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        let typedAt = clock.now
        clock.now += twin == .typedBeforeTheDictation ? 5 : 30
        _ = await hub.deliver("yes", to: Self.id("t1"), request: "q1")
        ended(hub, "Typed one.", took: ["yes"], at: typedAt)
        #expect(origins.isEmpty)
        let dictatedAt = clock.now
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-2", prompt: nil))
        ended(hub, "Dictated one.", took: ["yes"], at: dictatedAt)
        #expect(origins == ["q1"])
    }

    enum Sent: Sendable, CaseIterable { case beforeTheTurnStarted, whileItRan, afterTheHostEndedItBeforeTheAppHeard, afterItEnded }
    enum TypedTwin: Sendable, CaseIterable { case none, beforeTheDictation, afterTheDictation }
    enum Record: Sendable, CaseIterable { case present, empty, absent }

    nonisolated static let acceptedGrid: [(Sent, TypedTwin, Record)] = Sent.allCases.flatMap { sent in
        TypedTwin.allCases.flatMap { twin in Record.allCases.map { (sent, twin, $0) } }
    }

    @Test(arguments: acceptedGrid)
    func aDictationsReplyIsReadOnceForTheTurnThatTookItHoweverItsEventsAndTheHostsRecordArrive(sent: Sent, twin: TypedTwin, record: Record) async {
        let clock = AgentHubTests.Clock()
        let (hub, _) = await accepting(FakeHost(), clock: clock)
        var read: [(String?, String)] = []
        hub.onResult = { _, _, answer, _, origin, _ in read.append((origin, answer)) }
        let words = "yes do it"
        let typedBefore = clock.now
        clock.now += 10
        var dictatedAt: Date?
        func dictate() async {
            dictatedAt = clock.now
            _ = await hub.deliver(words, to: Self.id("t1"), request: "q1")
            clock.now += 5
        }
        if sent == .beforeTheTurnStarted { await dictate() }
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: AgentPromptDigest.of(sent == .beforeTheTurnStarted ? words : "typed in bb")))
        clock.now += 5
        if sent == .whileItRan { await dictate() }
        clock.now += 5
        var took: [(String, Date)] = []
        switch twin {
        case .none: break
        case .beforeTheDictation: took.append((words, typedBefore))
        case .afterTheDictation: took.append((words, clock.now))
        }
        if let dictatedAt { took.append((words, dictatedAt)) }
        took.sort { $0.1 < $1.1 }
        if sent == .afterTheHostEndedItBeforeTheAppHeard {
            clock.now += 2
            await dictate()
        }
        let accepted: [AgentAcceptedMessage]? = switch record {
        case .present: took.map { AgentAcceptedMessage(digest: AgentPromptDigest.of($0.0), at: $0.1) }
        case .empty: []
        case .absent: nil
        }
        hub.handle(.turnComplete(
            session: Self.id("t1"), reason: "complete", answer: "first",
            after: AgentTurnInput(from: nil, prompt: AgentPromptDigest.of(sent == .beforeTheTurnStarted ? words : "typed in bb"), accepted: accepted)))
        if sent == .afterItEnded { await dictate() }
        clock.now += 5
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-2", prompt: nil))
        ended(hub, "second", took: [words], at: dictatedAt)
        let firstTookIt = switch sent {
        case .beforeTheTurnStarted, .whileItRan: record != .empty
        case .afterTheHostEndedItBeforeTheAppHeard: record == .absent
        case .afterItEnded: false
        }
        #expect(read.map(\.0) == ["q1"])
        #expect(read.map(\.1) == [firstTookIt ? "first" : "second"])
    }

    @Test(arguments: [true, false])
    func aTurnWhoseHostCouldNotGiveItsRecordFallsBackToThePromptItStartedWith(promptKnown: Bool) async {
        let (hub, _) = await accepting(FakeHost())
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        _ = await hub.deliver("reply with one", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        ended(hub, "One.", took: nil, prompt: promptKnown ? "reply with one" : nil)
        #expect(origins == (promptKnown ? ["q1"] : []))
    }

    @Test func aDictationWhoseWaitRanOutBeforeATurnStartedIsNeverTakenForThatTurn() async {
        let clock = AgentHubTests.Clock()
        let (hub, _) = await accepting(FakeHost(), clock: clock)
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        _ = await hub.deliver("continue", to: Self.id("t1"), request: "q1")
        clock.now += AgentHub.hostTurnWait + 1
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: AgentPromptDigest.of("continue")))
        ended(hub, "Typed later.", took: ["continue"])
        #expect(origins.isEmpty)
    }

    @Test func aLongTurnThatStartedWithinTheWaitStillTakesItsDictationWhenItEnds() async {
        let clock = AgentHubTests.Clock()
        let (hub, _) = await accepting(FakeHost(), clock: clock)
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        _ = await hub.deliver("refactor it", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        clock.now += AgentHub.hostTurnWait * 3
        ended(hub, "Refactored.", took: ["refactor it"])
        #expect(origins == ["q1"])
    }

    @Test(arguments: [nil, [String]()])
    func aTurnThatTookNoneOfTheDictationsReadsNothingAndLeavesThemForTheTurnThatDoes(took: [String]?) async {
        let (hub, _) = await accepting(FakeHost())
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        _ = await hub.deliver("reply with one", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: AgentPromptDigest.of("reply with one")))
        ended(hub, "Done.", took: took, from: .task)
        #expect(origins.isEmpty)
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-2", prompt: nil))
        ended(hub, "One.", took: ["reply with one"])
        #expect(origins == ["q1"])
    }

    @Test func aReplyAskedForWithTheToolIsReadEvenWhenTheTurnTookNoDictation() async {
        let (hub, _) = await accepting(FakeHost())
        hub.speaks = { true }
        var read: [(String?, Bool)] = []
        hub.onResult = { _, _, _, requested, origin, _ in read.append((origin, requested)) }
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        #expect(hub.notify(session: Self.id("t1"), turn: "turn-1", on: true))
        ended(hub, "Done.", took: ["typed in bb"])
        #expect(read.map(\.0) == [nil])
        #expect(read.map(\.1) == [true])
    }

    enum Arrival: Sendable, CaseIterable { case beforeStart, betweenStartAndEnd, afterEnd }
    enum Digest: Sendable, CaseIterable { case right, wrong, absent }

    nonisolated static let orderGrid: [(Arrival, Digest, Bool, Bool, Bool)] = Arrival.allCases.flatMap { arrival in
        Digest.allCases.flatMap { digest in
            [true, false].flatMap { followed in [true, false].flatMap { endId in [true, false].map { (arrival, digest, followed, endId, $0) } } }
        }
    }

    @Test(arguments: orderGrid)
    func aTurnTheHostNamesIsFollowedHoweverItsEventsAreOrdered(arrival: Arrival, digest: Digest, followed: Bool, endId: Bool, pending: Bool) async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        host.reportsTurns = true
        host.reportsDeliveredTurns = true
        host.delivery = pending ? .accepted : .uncertain
        let hub = makeHub(host)
        await hub.rescan()
        var notices: [(AgentReceipt, String)] = []
        hub.onNotice = { receipt, request, _ in notices.append((receipt, request)) }
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        let prompt: String? = switch digest {
        case .right: AgentPromptDigest.of("run the tests")
        case .wrong: AgentPromptDigest.of("something else")
        case .absent: nil
        }
        let named = followed ? "q1" : "never-sent"
        let session = Self.id("t1")
        let turnOne: @MainActor @Sendable () -> Void = {
            let delivered = { host.watcher?(.delivered(request: named, at: Self.location("t1"), turn: "turn-1")) }
            let start = { hub.handle(.turnStarted(session: session, turn: "turn-1", prompt: prompt)) }
            let end = { hub.handle(.turnComplete(session: session, reason: "complete", answer: "All pass.", after: nil, turn: endId ? "turn-1" : nil)) }
            switch arrival {
            case .beforeStart: delivered(); start(); end()
            case .betweenStartAndEnd: start(); delivered(); end()
            case .afterEnd: start(); end(); delivered()
            }
            hub.handle(.turnStarted(session: session, turn: "turn-2", prompt: nil))
        }
        if pending {
            host.whileDelivering = turnOne
            #expect(await hub.deliver("run the tests", to: session, request: "q1") == .sent("docs"))
        } else {
            #expect(await hub.deliver("run the tests", to: session, request: "q1") == .uncertain("docs"))
            turnOne()
        }
        hub.handle(.turnComplete(session: session, reason: "complete", answer: "Something unrelated.", after: nil, turn: endId ? "turn-2" : nil))
        #expect(origins == (followed ? ["q1"] : []))
        #expect(notices.filter { $0.1 == "q1" && $0.0 == .sent("docs") }.count == (followed && !pending ? 1 : 0))
    }

    private func namingHost() async -> (FakeHost, AgentHub, Results) {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        host.reportsTurns = true
        host.reportsDeliveredTurns = true
        let hub = makeHub(host)
        await hub.rescan()
        let results = Results()
        hub.onResult = { _, _, answer, _, origin, _ in results.all.append((origin, answer)) }
        return (host, hub, results)
    }

    final class Results { var all: [(String?, String)] = [] }

    private func settled(_ results: Results) async {
        let until = Date().addingTimeInterval(3)
        while results.all.isEmpty, Date() < until { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aLateEndOfAnEarlierTurnIsNeverTheReplyToATurnTheHostNamed() async {
        let (host, hub, results) = await namingHost()
        host.whileDelivering = { host.watcher?(.delivered(request: "q1", at: Self.location("t1"), turn: "turn-1")) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "from the earlier turn", after: nil, turn: "turn-0"))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "All pass.", after: nil, turn: "turn-1"))
        #expect(results.all.map(\.0) == ["q1"])
        #expect(results.all.map(\.1) == ["All pass."])
    }

    @Test(arguments: [false, true])
    func aTurnNamedWhileAnEarlierOneIsAwaitedIsFollowedWhenItRuns(earlierEndsFirst: Bool) async {
        let (host, hub, results) = await namingHost()
        host.whileDelivering = { host.watcher?(.delivered(request: "q0", at: Self.location("t1"), turn: "turn-0")) }
        _ = await hub.deliver("first", to: Self.id("t1"), request: "q0")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-0", prompt: nil))
        host.whileDelivering = { host.watcher?(.delivered(request: "q1", at: Self.location("t1"), turn: "turn-1")) }
        _ = await hub.deliver("second", to: Self.id("t1"), request: "q1")
        if earlierEndsFirst {
            hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "first done", after: nil, turn: "turn-0"))
            hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        } else {
            hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        }
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "second done", after: nil, turn: "turn-1"))
        #expect(results.all.last.map { [$0.0, $0.1] } == ["q1", "second done"])
        #expect(!results.all.contains { $0.0 == "q1" && $0.1 == "first done" })
    }

    @Test(arguments: [true, false], [true, false])
    func twoRequestsTheHostNamesIntoOneTurnAreOrderedByItsRecordNotByWhenTheReportsArrive(firstReportedFirst: Bool, firstTakenFirst: Bool) async {
        let (host, hub, results) = await namingHost()
        host.whileDelivering = {}
        _ = await hub.deliver("first", to: Self.id("t1"), request: "q0")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        _ = await hub.deliver("also this", to: Self.id("t1"), request: "q1")
        let reports = [
            AgentHostChange.delivered(request: "q0", at: Self.location("t1"), turn: "turn-1", position: firstTakenFirst ? 0 : 1),
            AgentHostChange.delivered(request: "q1", at: Self.location("t1"), turn: "turn-1", position: firstTakenFirst ? 1 : 0),
        ]
        for report in firstReportedFirst ? reports : reports.reversed() { host.watcher?(report) }
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "Both done.", after: nil, turn: "turn-1"))
        #expect(results.all.map(\.0) == [firstTakenFirst ? "q1" : "q0"])
    }

    @Test(arguments: [true, false])
    func aTurnThatEndedBeforeItsMessagesWereNamedIsReadForTheOneItsHostTookLast(lowerReportedFirst: Bool) async {
        let (host, hub, results) = await namingHost()
        host.record = ["turn-1": ["q0", "q1"]]
        host.whileDelivering = {}
        _ = await hub.deliver("first", to: Self.id("t1"), request: "q0")
        _ = await hub.deliver("also this", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "Both done.", after: nil, turn: "turn-1"))
        #expect(results.all.isEmpty)
        let reports = [
            AgentHostChange.delivered(request: "q0", at: Self.location("t1"), turn: "turn-1", position: 0),
            AgentHostChange.delivered(request: "q1", at: Self.location("t1"), turn: "turn-1", position: 1),
        ]
        for report in lowerReportedFirst ? reports : reports.reversed() { host.watcher?(report) }
        await settled(results)
        #expect(results.all.map(\.0) == ["q1"])
    }

    @Test(arguments: [true, false])
    func aTurnNamedBeforeItStartsIsReadForTheMessageItsHostTookLast(lowerReportedFirst: Bool) async {
        let (host, hub, results) = await namingHost()
        host.whileDelivering = { host.watcher?(.delivered(request: "q0", at: Self.location("t1"), turn: "turn-1", position: 0)) }
        _ = await hub.deliver("first", to: Self.id("t1"), request: "q0")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        host.whileDelivering = {}
        _ = await hub.deliver("next", to: Self.id("t1"), request: "q1")
        _ = await hub.deliver("and then", to: Self.id("t1"), request: "q2")
        let reports = [
            AgentHostChange.delivered(request: "q1", at: Self.location("t1"), turn: "turn-2", position: 0),
            AgentHostChange.delivered(request: "q2", at: Self.location("t1"), turn: "turn-2", position: 1),
        ]
        for report in lowerReportedFirst ? reports : reports.reversed() { host.watcher?(report) }
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "First done.", after: nil, turn: "turn-1"))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-2", prompt: nil))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "Both done.", after: nil, turn: "turn-2"))
        #expect(results.all.map(\.0) == ["q0", "q2"])
    }

    @Test func aRequestNamedIntoATurnAlreadyAwaitedForAnotherTakesTheReplyFromTheEarlierRequest() async {
        let (host, hub, results) = await namingHost()
        host.whileDelivering = { host.watcher?(.delivered(request: "q0", at: Self.location("t1"), turn: "turn-1")) }
        _ = await hub.deliver("first", to: Self.id("t1"), request: "q0")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        host.whileDelivering = { host.watcher?(.delivered(request: "q1", at: Self.location("t1"), turn: "turn-1")) }
        #expect(await hub.deliver("also this", to: Self.id("t1"), request: "q1") == .sent("docs"))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "Both done.", after: nil, turn: "turn-1"))
        #expect(results.all.map(\.0) == ["q1"])
    }

    @Test func aConversationDisconnectedWhileItsTurnRecordIsReadGetsNoReply() async {
        let (host, hub, results) = await namingHost()
        host.recordStalls = true
        host.whileDelivering = { host.watcher?(.delivered(request: "q0", at: Self.location("t1"), turn: "turn-1")) }
        _ = await hub.deliver("first", to: Self.id("t1"), request: "q0")
        host.whileDelivering = nil
        host.delivery = .uncertain
        _ = await hub.deliver("second", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "First done.", after: nil, turn: "turn-1"))
        hub.disconnect(Self.id("t1"))
        try? await Task.sleep(for: AgentHub.turnRecordBudget + .milliseconds(500))
        #expect(results.all.isEmpty)
    }

    @Test func aStalledTurnRecordIsCancelledAndItsKnownReplyStillArrives() async {
        let (host, hub, results) = await namingHost()
        let received = Signal("reply after a stalled turn record")
        hub.onResult = { _, _, answer, _, origin, _ in
            results.all.append((origin, answer))
            received.fire()
        }
        host.recordStalls = true
        host.whileDelivering = { host.watcher?(.delivered(request: "q0", at: Self.location("t1"), turn: "turn-1")) }
        _ = await hub.deliver("first", to: Self.id("t1"), request: "q0")
        host.whileDelivering = nil
        host.delivery = .uncertain
        _ = await hub.deliver("second", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "First done.", after: nil, turn: "turn-1"))
        await received.wait()
        await host.recordCancelled.wait()
        #expect(results.all.map(\.0) == ["q0"])
    }

    @Test(arguments: [true, false])
    func aTurnEndingBetweenTheReportsOfTwoMessagesIsReadForTheOneItsHostTookLastWhenItsRecordCanBeRead(recordReadable: Bool) async {
        let (host, hub, results) = await namingHost()
        if recordReadable { host.record = ["turn-1": ["q0", "q1"]] }
        host.whileDelivering = { host.watcher?(.delivered(request: "q0", at: Self.location("t1"), turn: "turn-1")) }
        _ = await hub.deliver("first", to: Self.id("t1"), request: "q0")
        host.whileDelivering = nil
        host.delivery = .uncertain
        _ = await hub.deliver("second", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "turn-1", prompt: nil))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "First done.", after: nil, turn: "turn-1"))
        host.watcher?(.delivered(request: "q1", at: Self.location("t1"), turn: "turn-1"))
        await settled(results)
        #expect(results.all.map(\.0) == [recordReadable ? "q1" : "q0"])
    }

    @Test func anUncertainStartIsAnnouncedSentWhenItsTurnStartsEvenOnAHostThatNamesItsTurns() async {
        let host = FakeHost()
        host.reportsDeliveredTurns = true
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        var notices: [(AgentReceipt, String)] = []
        hub.onNotice = { receipt, request, _ in notices.append((receipt, request)) }
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        #expect(await startAnswering(hub, transport, answer: nil) == .uncertain("a new Example conversation"))
        hub.handle(.turnStarted(session: Self.id("t2"), turn: "a", prompt: AgentPromptDigest.of("plan the release")))
        hub.handle(.turnComplete(session: Self.id("t2"), reason: "complete", answer: "planned", after: nil, turn: "a"))
        #expect(notices.contains { $0.1 == "q1" && $0.0 == .sent("a new Example conversation") })
        #expect(origins == ["q1"])
    }

    static func claudeSession(_ native: String = "s1", pid: Int = 42) -> AgentSession {
        AgentSession(agent: "claude", id: native, pid: pid, cwd: "/src/docs", state: .idle)
    }

    static func hello(_ session: String, features: [String] = ["promptDigest"]) -> AgentEvent.Hello {
        AgentEvent.Hello(
            protocolVersion: 3, agent: "claude", agentVersion: "", instance: "i1", session: session, pid: 0, features: features,
            connection: "i1", installation: "inst-1")
    }

    private func joined(
        _ host: FakeHost, transport: FakeTransport = FakeTransport(), features: [String] = ["promptDigest"],
        allowed: @escaping @MainActor (String) -> Bool = { _ in true }, handOffLimit: Duration = .seconds(30),
        claude: FakeDiscovery = FakeDiscovery(kind: .claude), now: @escaping () -> Date = Date.init
    ) async -> AgentHub {
        host.conversations = [Self.thread("t1")]
        claude.result = .found([Self.claudeSession()])
        let hub = makeHub(
            host, transport: transport, allowed: allowed, claude: claude, environments: [42: ["EXAMPLE_THREAD": "t1", "HOME": "/x"]],
            handOffLimit: handOffLimit, now: now)
        await hub.rescan()
        #expect(hub.filing(for: Self.hello("claude:s1", features: features)) == Self.id("t1"))
        var filed = Self.hello(Self.id("t1"), features: features)
        filed.agent = "claude"
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(filed))
        await hub.rescan()
        return hub
    }

    private func pluginJoined(
        _ host: FakeHost, transport: FakeTransport, features: [String] = ["promptDigest", "merge"], draft: Bool = true
    ) async -> AgentHub {
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        transport.live.insert(Self.id("t1"))
        transport.liveInstances.insert(Self.pluginInstance)
        hub.handle(.hello(Self.pluginHello(Self.id("t1"), features: features)))
        await hub.rescan()
        if draft { hub.handle(.shown(session: Self.id("t1"), on: true, draft: true)) }
        return hub
    }

    static let pluginInstance = "plugin-1/t1"

    static func pluginHello(_ session: String, features: [String]) -> AgentEvent.Hello {
        var hello = hello(session, features: features)
        hello.agent = "example"
        hello.instance = pluginInstance
        hello.connection = "plugin-1"
        return hello
    }

    enum HolderEvent: Sendable { case listed, pluginHello, innerHello }
    enum PluginEnd: Sendable, CaseIterable { case live, silent, backAfterTheAgentFiled, backBeforeTheAgentSaidHello }

    nonisolated static let holderOrders: [[HolderEvent]] = [
        [.listed, .pluginHello, .innerHello], [.listed, .innerHello, .pluginHello], [.pluginHello, .listed, .innerHello],
        [.pluginHello, .innerHello, .listed], [.innerHello, .listed, .pluginHello], [.innerHello, .pluginHello, .listed],
    ]

    nonisolated static let holderGrid: [([HolderEvent], PluginEnd, Bool)] = holderOrders.flatMap { order in
        PluginEnd.allCases.flatMap { end in [true, false].map { (order, end, $0) } }
    }

    @Test(arguments: holderGrid)
    func whoHoldsAThreadDependsOnlyOnWhetherItsPluginIsConnectedWhateverOrderTheyArrivedIn(order: [HolderEvent], end: PluginEnd, rescans: Bool) async {
        let host = FakeHost()
        let transport = FakeTransport()
        let claude = FakeDiscovery(kind: .claude)
        claude.result = .found([Self.claudeSession()])
        let hub = makeHub(host, transport: transport, claude: claude, environments: [42: ["EXAMPLE_THREAD": "t1", "HOME": "/x"]])
        hub.speaks = { true }
        await hub.rescan()
        transport.live.insert(Self.id("t1"))
        var innerSession = "claude:s1"
        func innerHello() -> AgentEvent.Hello {
            var hello = Self.hello("claude:s1", features: ["promptDigest", "steer"])
            if let filed = hub.filing(for: hello) { hello.session = filed }
            innerSession = hello.session
            return hello
        }
        func step() async { if rescans, !host.conversations.isEmpty { await hub.rescan() } }
        for event in order {
            switch event {
            case .listed:
                host.conversations = [Self.thread("t1")]
                await hub.rescan()
            case .pluginHello:
                let hello = Self.pluginHello(Self.id("t1"), features: ["promptDigest", "merge"])
                _ = hub.filing(for: hello)
                transport.liveInstances.insert(Self.pluginInstance)
                hub.handle(.hello(hello))
            case .innerHello:
                transport.liveInstances.insert("i1")
                hub.handle(.hello(innerHello()))
            }
            await step()
        }
        switch end {
        case .live:
            break
        case .silent:
            transport.liveInstances.remove(Self.pluginInstance)
            await step()
            hub.handle(.hello(innerHello()))
        case .backAfterTheAgentFiled:
            transport.liveInstances.remove(Self.pluginInstance)
            await step()
            hub.handle(.hello(innerHello()))
            await step()
            transport.liveInstances.insert(Self.pluginInstance)
        case .backBeforeTheAgentSaidHello:
            transport.liveInstances.remove(Self.pluginInstance)
            await step()
            transport.liveInstances.insert(Self.pluginInstance)
            await step()
            hub.handle(.hello(innerHello()))
        }
        await step()
        let pluginHolds = end != .silent
        if end == .backAfterTheAgentFiled {
            await hub.rescan()
            #expect(transport.rehelloed.contains(Self.id("t1")))
        }
        #expect((hub.filing(for: Self.hello("claude:s1")) == nil) == pluginHolds)
        if pluginHolds { innerSession = "claude:s1" }
        _ = hub.notify(session: innerSession, turn: "", on: true)
        #expect(hub.readNextAloud == [Self.id("t1")])
        hub.handle(.shown(session: Self.id("t1"), on: true, draft: true))
        let receipt = await deliverAnswering(hub, transport) { .submitted(request: $0, turn: "") }
        if pluginHolds {
            #expect(receipt == .sentWithDraft("docs"))
            #expect(joinCommands(transport).map { transport.pinned[$0.id] } == [Self.pluginInstance])
        } else {
            #expect(joinCommands(transport).isEmpty)
            #expect(host.delivered.map(\.0) == ["run the tests"])
        }
    }

    @Test func aPluginHeardFromAgainBeforeAnyRescanStillSendsBackTheAgentFiledWhileItWasSilent() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let claude = FakeDiscovery(kind: .claude)
        claude.result = .found([Self.claudeSession()])
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host, transport: transport, claude: claude, environments: [42: ["EXAMPLE_THREAD": "t1", "HOME": "/x"]])
        await hub.rescan()
        transport.live.insert(Self.id("t1"))
        let plugin = Self.pluginHello(Self.id("t1"), features: ["promptDigest", "merge"])
        _ = hub.filing(for: plugin)
        transport.liveInstances.insert(Self.pluginInstance)
        hub.handle(.hello(plugin))
        await hub.rescan()
        transport.liveInstances.remove(Self.pluginInstance)
        transport.liveInstances.insert("i1")
        var inner = Self.hello("claude:s1", features: ["promptDigest"])
        #expect(hub.filing(for: inner) == Self.id("t1"))
        inner.session = Self.id("t1")
        hub.handle(.hello(inner))
        transport.liveInstances.insert(Self.pluginInstance)
        let before = transport.rehelloed.filter { $0 == Self.id("t1") }.count
        await hub.rescan()
        #expect(transport.rehelloed.filter { $0 == Self.id("t1") }.count == before + 1)
        #expect(hub.filing(for: Self.hello("claude:s1")) == nil)
        await hub.rescan()
        #expect(transport.rehelloed.filter { $0 == Self.id("t1") }.count == before + 1)
    }

    @Test func anAgentFiledInsideAThreadNeverTurnsOffItsHostPluginsDraftJoining() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport)
        var inner = Self.hello(Self.id("t1"), features: ["promptDigest"])
        inner.agent = "claude"
        hub.handle(.hello(inner))
        let receipt = await deliverAnswering(hub, transport) { .submitted(request: $0, turn: "") }
        #expect(receipt == .sentWithDraft("docs"))
        #expect(host.delivered.isEmpty)
    }

    @Test func anAgentInsideAThreadIsNotFiledWhileTheHostPluginHoldsItEvenWhenThePluginSaidHelloBeforeTheThreadWasListed() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let claude = FakeDiscovery(kind: .claude)
        claude.result = .found([Self.claudeSession()])
        let hub = makeHub(host, transport: transport, claude: claude, environments: [42: ["EXAMPLE_THREAD": "t1", "HOME": "/x"]])
        await hub.rescan()
        let plugin = Self.pluginHello(Self.id("t1"), features: ["promptDigest", "merge"])
        #expect(hub.filing(for: plugin) == nil)
        transport.live.insert(Self.id("t1"))
        transport.liveInstances.insert(Self.pluginInstance)
        hub.handle(.hello(plugin))
        host.conversations = [Self.thread("t1")]
        await hub.rescan()
        #expect(hub.filing(for: Self.hello("claude:s1")) == nil)
        transport.liveInstances.remove(Self.pluginInstance)
        #expect(hub.filing(for: Self.hello("claude:s1")) == Self.id("t1"))
    }

    @Test func aJoinGoesToTheHostPluginsOwnConnectionNotToAnAgentSharingTheThread() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport)
        _ = await deliverAnswering(hub, transport) { .submitted(request: $0, turn: "") }
        let wire = joinCommands(transport).first?.id ?? ""
        #expect(transport.pinned[wire] == Self.pluginInstance)
    }

    @Test func aDraftIsNotJoinedWhileTheHostPluginsOwnConnectionIsSilentEvenIfAnotherConnectorKeepsTheThreadLive() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport)
        transport.liveInstances.remove(Self.pluginInstance)
        let receipt = await deliverAnswering(hub, transport) { .submitted(request: $0, turn: "") }
        #expect(joinCommands(transport).isEmpty)
        #expect(receipt == .sent("docs"))
        #expect(host.delivered.map(\.0) == ["run the tests"])
    }

    private func joinCommands(_ transport: FakeTransport) -> [(id: String, text: String)] {
        transport.sent.compactMap { if case .submit(let id, _, let text, _, _, _, _, true) = $0.0 { (id, text) } else { nil } }
    }

    private func deliverAnswering(
        _ hub: AgentHub, _ transport: FakeTransport, inFront: Bool = true, answer: ((String) -> AgentEvent)?
    ) async -> AgentReceipt {
        let delivery = Task { await hub.deliver("run the tests", to: Self.id("t1"), request: "q1", inFront: inFront) }
        for _ in 0..<200 where joinCommands(transport).isEmpty { await Task.yield() }
        if let wire = joinCommands(transport).first?.id, let answer { hub.handle(answer(wire)) }
        return await delivery.value
    }

    @Test func aDictationForTheThreadInFrontJoinsWhatTheUserTypedThroughTheHostsOwnPlugin() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport)
        let receipt = await deliverAnswering(hub, transport) { .submitted(request: $0, turn: "") }
        #expect(receipt == .sentWithDraft("docs"))
        #expect(joinCommands(transport).map(\.text) == ["run the tests"])
        #expect(host.delivered.isEmpty)
    }

    @Test(arguments: [
        ("draft", AgentReceipt.kept("docs", reason: .composing)),
        ("added", AgentReceipt.kept("docs", reason: .inPromptBox(.besideText))),
    ])
    func aDraftTheHostsPluginCouldNotSendIsKeptAndNeverSentAgainThroughTheHost(refusal: String, receipt: AgentReceipt) async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport)
        #expect(await deliverAnswering(hub, transport) { .refused(request: $0, reason: refusal) } == receipt)
        #expect(host.delivered.isEmpty)
    }

    @Test func aJoinTheHostsPluginNeverAnswersIsUncertainAndNeverSentAgainThroughTheHost() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport)
        #expect(await deliverAnswering(hub, transport, answer: nil) == .uncertain("docs"))
        #expect(host.delivered.isEmpty)
    }

    @Test func aJoinThePluginCannotTellWhetherBbSentIsUncertainAndNeverSentAgainThroughTheHost() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport)
        #expect(await deliverAnswering(hub, transport) { .refused(request: $0, reason: "unclear") } == .uncertain("docs"))
        #expect(host.delivered.isEmpty)
    }

    @Test(arguments: ["empty", "unsupported", "a reason this version does not know"])
    func aJoinThatPutNothingInTheMessageBoxGoesThroughItsHostAsBefore(refusal: String) async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport)
        #expect(await deliverAnswering(hub, transport) { .refused(request: $0, reason: refusal) } == .sent("docs"))
        #expect(host.delivered.map(\.0) == ["run the tests"])
    }

    @Test func aThreadIsSaidToHaveTextInItsMessageBoxOnlyWhileItsPluginSaysSo() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport)
        #expect(hub.showsDraft(Self.id("t1")))
        hub.handle(.shown(session: Self.id("t1"), on: true))
        #expect(!hub.showsDraft(Self.id("t1")))
        hub.handle(.shown(session: Self.id("t1"), on: true, draft: true))
        hub.handle(.shown(session: Self.id("t1"), on: false))
        #expect(!hub.showsDraft(Self.id("t1")))
    }

    @Test func aThreadShownWithAnEmptyMessageBoxIsNeverAskedToJoin() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport, draft: false)
        hub.handle(.shown(session: Self.id("t1"), on: true))
        #expect(await hub.deliver("run the tests", to: Self.id("t1"), request: "q1", inFront: true) == .sent("docs"))
        #expect(joinCommands(transport).isEmpty)
        #expect(host.delivered.count == 1)
    }

    @Test func aThreadNotInFrontNeverHasItsDraftJoined() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport)
        #expect(await hub.deliver("run the tests", to: Self.id("t1"), request: "q1") == .sent("docs"))
        #expect(joinCommands(transport).isEmpty)
        #expect(host.delivered.count == 1)
    }

    @Test func anAgentsOwnConnectorFiledUnderAHostedThreadIsNeverAskedToJoinItsDraft() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await joined(host, transport: transport, features: ["promptDigest", "merge"])
        #expect(await hub.deliver("run the tests", to: Self.id("t1"), request: "q1", inFront: true) == .sent("docs"))
        #expect(joinCommands(transport).isEmpty)
        #expect(host.delivered.count == 1)
    }

    @Test func aDictationJoinedToADraftIsFollowedIntoTheTurnItsPluginReportsForIt() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport)
        var replies: [String] = []
        hub.onResult = { _, _, reply, _, _, _ in replies.append(reply) }
        _ = await deliverAnswering(hub, transport) { .submitted(request: $0, turn: "") }
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("run the tests")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "done"))
        #expect(replies == ["done"])
    }

    static let newConversation = AgentHub.newConversation(in: "example")
    static let window = AgentHostApp(bundle: "dev.example.app", pid: 50, name: "Example", window: "cg:7", instance: instance)

    private func startReady(_ host: FakeHost, transport: FakeTransport, features: [String] = ["promptDigest", "merge", "start"]) async -> AgentHub {
        let hub = await pluginJoined(host, transport: transport, features: features, draft: false)
        host.window = Self.window
        hub.handle(.shown(session: Self.id("t1"), on: false, newConversation: true))
        return hub
    }

    private func startCommands(_ transport: FakeTransport) -> [(id: String, session: String, text: String)] {
        transport.sent.compactMap { if case .start(let id, let session, let text, _) = $0.0 { (id, session, text) } else { nil } }
    }

    private func startAnswering(
        _ hub: AgentHub, _ transport: FakeTransport, text: String = "plan the release", inFront: Bool = true, answer: ((String) -> AgentEvent)?
    ) async -> AgentReceipt {
        let delivery = Task { await hub.deliver(text, to: Self.newConversation, request: "q1", inFront: inFront) }
        for _ in 0..<200 where startCommands(transport).isEmpty { await Task.yield() }
        if let wire = startCommands(transport).first?.id, let answer { hub.handle(answer(wire)) }
        return await delivery.value
    }

    @Test func aStartedConversationWhoseTurnCompletesBeforeTurnStartedStillDeliversItsReply() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        var replies: [(String, String?)] = []
        hub.onResult = { _, _, answer, _, origin, _ in replies.append((answer, origin)) }
        let receipt = await startAnswering(hub, transport, text: "Reply with only tabside.") { .submitted(request: $0, turn: "") }
        #expect(receipt == .sent("a new Example conversation"))
        let fresh = Self.id("t238")
        hub.handle(.turnComplete(
            session: fresh, reason: "complete", answer: "tabside",
            after: AgentTurnInput(from: nil, prompt: AgentPromptDigest.of("Reply with only tabside."))))
        #expect(replies.map(\.0) == ["tabside"])
        #expect(replies.map(\.1) == ["q1"])
    }

    @Test func aHostsNewConversationBoxIsInFrontOnlyWhileItsPluginSaysSoAndTheHostsWindowIsFocused() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        let front = FrontSession(id: Self.newConversation, app: FrontApp(bundle: "dev.example.app", pid: 50, name: "Example", window: "cg:7"))
        #expect(await hub.newConversationInFront() == front)
        #expect(hub.newConversationName(Self.newConversation) == "a new Example conversation")
        #expect(hub.newConversationName(Self.id("t1")) == nil)
        host.window = nil
        #expect(await hub.newConversationInFront() == nil)
        host.window = Self.window
        transport.live = []
        #expect(await hub.newConversationInFront() == nil)
        transport.live = [Self.id("t1")]
        hub.handle(.shown(session: Self.id("t1"), on: true))
        #expect(await hub.newConversationInFront() == nil)
        hub.handle(.shown(session: Self.id("t1"), on: false, newConversation: true))
        #expect(await hub.newConversationInFront() == front)
        hub.handle(.shown(session: Self.id("t1"), on: false))
        #expect(await hub.newConversationInFront() == nil)
    }

    @Test func aHostWithNoConversationsYetStartsOneThroughThePluginsNewConversationConnection() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        let carrier = Self.id("new conversation")
        var hello = Self.hello(carrier, features: ["promptDigest", "merge", "start"])
        hello.agent = "example"
        transport.live.insert(carrier)
        let scans = host.scans
        hub.handle(.hello(hello))
        await hub.rescan()
        #expect(host.scans == scans)
        #expect(hub.directory.conversations.isEmpty)
        host.window = Self.window
        hub.handle(.shown(session: carrier, on: false, newConversation: true))
        let receipt = await startAnswering(hub, transport) {
            .submitted(request: $0, turn: "", report: AgentDeliveryReport(state: .seen, withDraft: false))
        }
        #expect(receipt == .sent("a new Example conversation"))
        #expect(startCommands(transport).map(\.session) == [carrier])
        #expect(hub.directory.conversations.isEmpty)
    }

    @Test func aCopyWithoutThePluginIsNamedEvenBeforeTheHostIsTurnedOn() async {
        let host = FakeHost()
        host.copy = AgentHostCopy(name: "Example Work", instance: Self.instance, enrolled: false)
        let hub = makeHub(host, allowed: { _ in false })
        #expect(await hub.hostCopyNotReadyInFront() == .missing("Example Work"))
    }

    @Test func aNewConversationPageOneCopyReportedIsNeverInFrontWhileAnotherCopyIs() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        host.window?.instance = "/Users/a/.work-bb"
        #expect(await hub.newConversationInFront() == nil)
        host.window?.instance = Self.instance
        #expect(await hub.newConversationInFront() != nil)
        host.window?.instance = nil
        #expect(await hub.newConversationInFront() == nil)
    }

    @Test func eachCopyOfAHostKeepsWhatItLastShowedSoSwitchingCopiesNeedsNoNewReport() async {
        let other = "/Users/a/.work-bb"
        let host = FakeHost()
        host.conversations = [Self.thread("a1"), Self.thread("b1", instance: other)]
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        for id in [Self.id("a1"), Self.id("b1", instance: other), Self.id("new conversation"), Self.id("new conversation", instance: other)] {
            transport.live.insert(id)
            var hello = Self.hello(id, features: ["promptDigest", "merge", "start"])
            hello.agent = "example"
            hello.instance = "plugin/" + id
            hub.handle(.hello(hello))
        }
        await hub.rescan()
        hub.handle(.shown(session: Self.id("a1"), on: true))
        hub.handle(.shown(session: Self.id("b1", instance: other), on: true))
        host.window = AgentHostApp(bundle: "dev.example.app", pid: 50, name: "Example", window: "cg:7", instance: Self.instance)
        _ = await hub.sessionInFrontWithoutAsking()
        #expect(host.reported.last == Self.location("a1"))
        hub.handle(.shown(session: Self.id("new conversation"), on: false, newConversation: true))
        hub.handle(.shown(session: Self.id("new conversation", instance: other), on: true))
        #expect(await hub.newConversationInFront() != nil)
    }

    @Test func aCopyOfAHostInFrontThatCannotBeHeardIsNamedWithWhatIsMissing() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        #expect(await hub.hostCopyNotReadyInFront() == nil)
        host.copy = AgentHostCopy(name: "Example Work", instance: Self.instance, enrolled: false)
        #expect(await hub.hostCopyNotReadyInFront() == .missing("Example Work"))
        host.copy?.enrolled = true
        #expect(await hub.hostCopyNotReadyInFront() == .notConnected("Example Work"))
        host.copy?.setUp = false
        #expect(await hub.hostCopyNotReadyInFront() == .notSetUp("Example Work"))
        host.copy?.setUp = true
        transport.live.insert(Self.id("new conversation"))
        #expect(await hub.hostCopyNotReadyInFront() == .windowUnknown("Example Work"))
        transport.live = []
        host.conversations = [Self.thread("t1")]
        transport.live.insert(Self.id("t1"))
        var hello = Self.hello(Self.id("t1"))
        hello.agent = "example"
        hub.handle(.hello(hello))
        await hub.rescan()
        #expect(await hub.hostCopyNotReadyInFront() == .windowUnknown("Example Work"))
    }

    @Test func aHostThatSaysItsListChangedIsScannedAgainAtOnce() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        #expect(hub.directory.conversations.map(\.id) == [Self.id("t1")])
        host.conversations = [Self.thread("t1"), Self.thread("t2")]
        await hub.rescan()
        #expect(hub.directory.conversations.count == 1)
        let before = host.scans
        host.watcher?(.listing)
        #expect(await BBHostTests.within { host.scans > before })
        await hub.rescan(rereadingTitles: false)
        #expect(Set(hub.directory.conversations.map(\.id)) == [Self.id("t1"), Self.id("t2")])
    }

    @Test func aStateTheHostReportsShowsOnItsRowWithoutListingAgain() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1"), Self.thread("t2")]
        let hub = makeHub(host)
        await hub.rescan()
        let before = host.scans
        host.watcher?(.state(Self.location("t1"), .working))
        #expect(hub.directory.conversations.first { $0.id == Self.id("t1") }?.state == .working)
        #expect(hub.directory.conversations.first { $0.id == Self.id("t2") }?.state == .idle)
        host.watcher?(.state(Self.location("t1"), .waitingApproval))
        #expect(hub.directory.conversations.first { $0.id == Self.id("t1") }?.state == .waitingApproval)
        #expect(host.scans == before)
    }

    @Test func aListingAfterTheReportedStateIsWhatTheRowShows() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        host.watcher?(.state(Self.location("t1"), .working))
        let before = host.scans
        host.watcher?(.listing)
        #expect(await BBHostTests.within { host.scans > before })
        await hub.rescan(rereadingTitles: false)
        #expect(hub.directory.conversations.first?.state == .idle)
    }

    @Test func aStateForAConversationTheHostNeverListedOrAnotherHostIsIgnored() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        host.watcher?(.state(Self.location("gone"), .working))
        host.watcher?(.state(AgentHostLocation(host: "other", instance: Self.instance, native: "t1"), .working))
        #expect(hub.directory.conversations.map(\.id) == [Self.id("t1")])
        #expect(hub.directory.conversations.first?.state == .idle)
    }

    @Test func aTurnTheConnectorReportsAfterTheHostsStateIsWhatTheRowShows() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        var hello = Self.hello(Self.id("t1"), features: ["promptDigest", "readiness", "notify"])
        hello.agent = "example"
        hello.idle = true
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(hello))
        await hub.rescan()
        host.watcher?(.state(Self.location("t1"), .working))
        #expect(hub.directory.conversations.first?.state == .working)
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "done", after: nil))
        await hub.rescan(rereadingTitles: false)
        #expect(hub.directory.conversations.first?.state == .idle)
        host.watcher?(.state(Self.location("t1"), .working))
        #expect(hub.directory.conversations.first?.state == .working)
    }

    @Test func aHelloThatReportsNoTurnsKeepsTheStateTheHostReported() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        host.watcher?(.state(Self.location("t1"), .working))
        var hello = Self.hello(Self.id("t1"), features: ["promptDigest"])
        hello.agent = "example"
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(hello))
        await hub.rescan(rereadingTitles: false)
        #expect(hub.directory.conversations.first?.state == .working)
    }

    @Test func conversationsAHostTitlesAlikeAreToldApartByTheWorkspaceItNames() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1"), Self.thread("t2")]
        host.titles = [Self.location("t1").conversationKey: "@agent", Self.location("t2").conversationKey: "@agent"]
        host.workspaces = [Self.location("t1").conversationKey: "app", Self.location("t2").conversationKey: "web"]
        let hub = makeHub(host)
        await hub.rescan()
        #expect(Set(hub.directory.conversations.map(\.handle)) == ["app agent", "web agent"])
    }

    @Test func aConversationAloneWithItsTitleKeepsThePlainNameWhateverWorkspaceHoldsIt() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        host.titles = [Self.location("t1").conversationKey: "@agent"]
        host.workspaces = [Self.location("t1").conversationKey: "app"]
        let hub = makeHub(host)
        await hub.rescan()
        #expect(hub.directory.conversations.map(\.handle) == ["agent"])
    }

    enum RenameArrival: Sendable, CaseIterable { case beforeHostCall, duringHostCall, duringRescan, afterLoopEnds }

    nonisolated static let renameGrid: [(RenameArrival, Bool)] = RenameArrival.allCases.flatMap { arrival in [true, false].map { (arrival, $0) } }

    private func settle(_ done: () -> Bool) async {
        for _ in 0..<2000 where !done() { try? await Task.sleep(for: .milliseconds(1)) }
    }

    @Test(arguments: renameGrid)
    func aSecondRenameReachesTheHostAfterTheFirstWhenEverItArrives(arrival: RenameArrival, hostRenames: Bool) async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        host.renames = hostRenames
        let hub = makeHub(host, hostDeadline: .seconds(10))
        await hub.rescan()
        let scansBefore = host.scans
        let expected: [String]
        switch arrival {
        case .beforeHostCall:
            try hub.rename(Self.id("t1"), to: "alpha")
            try hub.rename(Self.id("t1"), to: "beta")
            expected = ["beta"]
        case .duringHostCall:
            host.renameGate.closed = true
            try hub.rename(Self.id("t1"), to: "alpha")
            await settle { host.renameGate.waiting == 1 }
            try #require(host.renameGate.waiting == 1)
            try hub.rename(Self.id("t1"), to: "beta")
            host.renameGate.open()
            expected = ["alpha", "beta"]
        case .duringRescan:
            host.scanGate.closed = hostRenames
            try hub.rename(Self.id("t1"), to: "alpha")
            if hostRenames {
                await settle { host.scanGate.waiting == 1 }
                try #require(host.scanGate.waiting == 1)
            } else {
                await settle { host.retitled.count == 1 && host.renaming == 0 }
            }
            host.renameGate.closed = true
            try hub.rename(Self.id("t1"), to: "beta")
            host.scanGate.open()
            for _ in 0..<50 { await Task.yield() }
            host.renameGate.open()
            expected = ["alpha", "beta"]
        case .afterLoopEnds:
            try hub.rename(Self.id("t1"), to: "alpha")
            await settle { host.retitled.count == 1 && host.renaming == 0 && (!hostRenames || host.scans > scansBefore) }
            try hub.rename(Self.id("t1"), to: "beta")
            expected = ["alpha", "beta"]
        }
        await settle { host.retitled.count >= expected.count && host.renaming == 0 }
        for _ in 0..<20 { await Task.yield() }
        #expect(host.retitled.map(\.1) == expected)
        #expect(host.mostRenaming == 1)
    }

    @Test func aPromptTheConnectorReportsOutranksTheHostsState() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        var hello = Self.hello(Self.id("t1"), features: ["promptDigest", "readiness"])
        hello.agent = "example"
        hello.waiting = AgentPrompt(kind: "confirm", title: "Run it?")
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(hello))
        await hub.rescan()
        host.watcher?(.state(Self.location("t1"), .working))
        #expect(hub.directory.conversations.first?.state == .userDialog)
    }

    @Test func aStoppedHubStopsWatchingItsHosts() {
        let host = FakeHost()
        let hub = makeHub(host)
        #expect(host.unwatched == 0)
        hub.stop()
        #expect(host.unwatched == 1)
    }

    @Test func aConnectedCopyInFrontSaysWhichStepBeforeSendingIsMissing() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport, draft: false)
        host.copy = AgentHostCopy(name: "Example Work", instance: Self.instance, enrolled: true)
        host.window = nil
        #expect(await hub.hostCopyNotReadyInFront() == .windowUnknown("Example Work"))
        host.window = Self.window
        #expect(await hub.hostCopyNotReadyInFront() == .nothingShown("Example Work"))
        transport.live.insert(Self.id("t9"))
        hub.handle(.shown(session: Self.id("t9"), on: true))
        #expect(await hub.hostCopyNotReadyInFront() == .notListed("Example Work"))
        transport.live.remove(Self.id("t9"))
        #expect(await hub.hostCopyNotReadyInFront() == .nothingShown("Example Work"))
        hub.handle(.shown(session: Self.id("t1"), on: true))
        #expect(await hub.hostCopyNotReadyInFront() == nil)
        hub.handle(.shown(session: Self.id("t1"), on: false, newConversation: true))
        #expect(await hub.hostCopyNotReadyInFront() == .cannotStart("Example Work"))
    }

    @Test func aCopyWhoseWindowCannotBeReadForLackOfAccessibilitySaysSo() async {
        let host = FakeHost()
        let transport = FakeTransport()
        host.conversations = [Self.thread("t1")]
        var trusted = false
        let hub = makeHub(host, transport: transport, accessibility: { trusted })
        await hub.rescan()
        var hello = Self.hello(Self.id("t1"))
        hello.agent = "example"
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(hello))
        host.copy = AgentHostCopy(name: "Example Work", instance: Self.instance, enrolled: true)
        #expect(await hub.hostCopyNotReadyInFront() == .needsAccessibility("Example Work"))
        trusted = true
        #expect(await hub.hostCopyNotReadyInFront() == .windowUnknown("Example Work"))
    }

    @Test func aConnectedCopyThatCanStartAConversationOnItsNewConversationPageIsReady() async {
        let host = FakeHost()
        let hub = await startReady(host, transport: FakeTransport())
        host.copy = AgentHostCopy(name: "Example Work", instance: Self.instance, enrolled: true)
        #expect(await hub.hostCopyNotReadyInFront() == nil)
    }

    @Test func aPluginThatCannotStartConversationsNeverPutsANewConversationInFront() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport, features: ["promptDigest", "merge"])
        #expect(await hub.newConversationInFront() == nil)
    }

    @Test func disconnectingTheConversationThatCarriesTheNewConversationReportForgetsIt() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        hub.disconnect(Self.id("t1"))
        #expect(await hub.newConversationInFront() == nil)
    }

    @Test(arguments: [false, true])
    func aDictationForANewConversationIsStartedByTheHostsPluginAndSaidSent(withDraft: Bool) async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        let receipt = await startAnswering(hub, transport) {
            .submitted(request: $0, turn: "", report: AgentDeliveryReport(state: .seen, withDraft: withDraft))
        }
        #expect(receipt == (withDraft ? .sentWithDraft("a new Example conversation") : .sent("a new Example conversation")))
        #expect(startCommands(transport).map(\.session) == [Self.id("t1")])
        #expect(startCommands(transport).map(\.text) == ["plan the release"])
        #expect(host.delivered.isEmpty)
    }

    @Test(arguments: [
        ("draft", AgentReceipt.kept("a new Example conversation", reason: .composing)),
        ("added", .kept("a new Example conversation", reason: .inPromptBox(.besideText))),
        ("filled", .kept("a new Example conversation", reason: .inPromptBox(.awaitingReturn))),
        ("gone", .notSent(nil, reason: .newConversationNotInFront("Example"))),
        ("command", .notSent(nil, reason: .couldNotStart("Example"))),
        ("a reason this version does not know", .notSent(nil, reason: .couldNotStart("Example"))),
    ])
    func aNewConversationThePluginCouldNotStartSaysWhatHappenedAndIsNeverSentElsewhere(refusal: String, receipt: AgentReceipt) async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        #expect(await startAnswering(hub, transport) { .refused(request: $0, reason: refusal) } == receipt)
        #expect(host.delivered.isEmpty)
        #expect(joinCommands(transport).isEmpty)
    }

    @Test(arguments: ["filled", "added"])
    func aNewConversationTheHostWouldNotStartSaysWhatTheHostSaid(refusal: String) async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        let receipt = await startAnswering(hub, transport) { .refused(request: $0, reason: refusal, detail: "Enter a prompt or attach a file.") }
        #expect(receipt == .kept(
            "a new Example conversation", reason: .declined(by: "Example", saying: "Enter a prompt or attach a file.", besideText: refusal == "added")))
    }

    @Test func aNewConversationThePluginNeverAnswersIsUncertain() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        #expect(await startAnswering(hub, transport, answer: nil) == .uncertain("a new Example conversation"))
    }

    @Test func aNewConversationThePluginCannotTellWhetherBbStartedIsUncertain() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        #expect(await startAnswering(hub, transport) { .refused(request: $0, reason: "unclear") } == .uncertain("a new Example conversation"))
    }

    @Test func aNewConversationNoLongerInFrontIsNeverStarted() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        #expect(await startAnswering(hub, transport, inFront: false, answer: nil) == .notSent(nil, reason: .newConversationNotInFront("Example")))
        hub.handle(.shown(session: Self.id("t1"), on: true))
        #expect(await startAnswering(hub, transport, answer: nil) == .notSent(nil, reason: .newConversationNotInFront("Example")))
        #expect(startCommands(transport).isEmpty)
    }

    @Test func theConversationADictationStartedIsFollowedIntoItsFirstTurnAndItsReplyIsHeard() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        var replies: [(String, String, String?)] = []
        hub.onResult = { conversation, _, reply, _, origin, _ in replies.append((conversation, reply, origin)) }
        _ = await startAnswering(hub, transport) { .submitted(request: $0, turn: "") }
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "x", prompt: AgentPromptDigest.of("plan the release")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "not this one"))
        hub.handle(.turnStarted(session: Self.id("t2"), turn: "a", prompt: AgentPromptDigest.of("plan the release")))
        hub.handle(.turnComplete(session: Self.id("t2"), reason: "complete", answer: "planned"))
        #expect(replies.map(\.0) == [Self.id("t2")])
        #expect(replies.map(\.1) == ["planned"])
        #expect(replies.map(\.2) == ["q1"])
    }

    @Test func aNewConversationStartedInOneCopyIsNeverFollowedIntoAnotherCopysThreadWithTheSameText() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        var replies: [String] = []
        hub.onResult = { conversation, _, _, _, _, _ in replies.append(conversation) }
        _ = await startAnswering(hub, transport) { .submitted(request: $0, turn: "") }
        let elsewhere = Self.id("t9", instance: "/Users/a/.work-bb")
        hub.handle(.turnStarted(session: elsewhere, turn: "b", prompt: AgentPromptDigest.of("plan the release")))
        hub.handle(.turnComplete(session: elsewhere, reason: "complete", answer: "theirs"))
        hub.handle(.turnStarted(session: Self.id("t2"), turn: "a", prompt: AgentPromptDigest.of("plan the release")))
        hub.handle(.turnComplete(session: Self.id("t2"), reason: "complete", answer: "planned"))
        #expect(replies == [Self.id("t2")])
    }

    @Test func aHostThatReportsItsOwnTurnsHasTheReplyToADeliveryHeardWithNoConnectorSayingHello() async {
        let host = FakeHost()
        host.reportsTurns = true
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        var replies: [(String, String, String?)] = []
        hub.onResult = { conversation, _, reply, _, origin, _ in replies.append((conversation, reply, origin)) }
        #expect(await hub.deliver("plan the release", to: Self.id("t1"), request: "q1") == .sent(hub.directory.conversations[0].handle))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("plan the release")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "planned"))
        #expect(replies.map(\.1) == ["planned"])
        #expect(replies.map(\.2) == ["q1"])
        #expect(host.observed.contains(.turnStarted(session: Self.location("t1").conversationKey, turn: "a", prompt: AgentPromptDigest.of("plan the release"))))
    }

    @Test(arguments: ["a", "b"])
    func aSteeredTurnEndsWhicheverTurnIdItsStopCarries(stoppedTurn: String) async {
        let host = FakeHost()
        host.reportsTurns = true
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("plan the release")))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "b", prompt: AgentPromptDigest.of("and the notes")))
        let stop = AgentEvent.turnComplete(session: Self.location("t1").conversationKey, reason: "complete", answer: "planned", turn: stoppedTurn)
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "planned", turn: stoppedTurn))
        #expect(host.observed.last == stop)
    }

    @Test func theTurnAConversationLastEndedIsForgottenOnceTheConversationIsGone() async {
        let host = FakeHost()
        host.reportsTurns = true
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "done", turn: "a"))
        #expect(hub.connectorStateSessions.contains(Self.id("t1")))
        host.conversations = []
        host.watcher?(.listing)
        await hub.rescan()
        #expect(!hub.connectorStateSessions.contains(Self.id("t1")))
    }

    @Test func aSecondCompletionOfATurnThatAlreadyEndedIsIgnoredBeforeAnyoneSeesIt() async {
        let host = FakeHost()
        host.reportsTurns = true
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        var replies: [String] = []
        hub.onResult = { _, _, reply, _, _, _ in replies.append(reply) }
        _ = await hub.deliver("plan the release", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("plan the release")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "planned", turn: "a"))
        _ = await hub.deliver("now the notes", to: Self.id("t1"), request: "q2")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "b", prompt: AgentPromptDigest.of("now the notes")))
        let seen = host.observed.count
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "planned", turn: "a"))
        #expect(host.observed.count == seen)
        #expect(replies == ["planned"])
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "noted", turn: "b"))
        #expect(replies == ["planned", "noted"])
    }

    @Test func aHostedConversationShownByATerminalProcessOpensThroughThatTerminalWhenTheHostCannotOpenIt() async {
        let host = FakeHost()
        host.opening = .unsupported
        host.conversations = [Self.thread("t1", pid: 4242)]
        let focus = FakeFocus()
        let hub = makeHub(host, focus: focus)
        await hub.rescan()
        #expect(await hub.open(Self.id("t1")) == .exact)
        #expect(focus.focused.map(\.1) == [4242])
    }

    @Test func aHostedConversationShownByATerminalProcessIsFoundInFrontThroughThatProcess() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1", pid: 4242), Self.thread("t2")]
        let front = FakeFront()
        front.answer = FrontSession(id: Self.id("t1"), app: FrontApp(bundle: "com.example.term", pid: 9, name: "Term"))
        let hub = makeHub(host, front: front)
        await hub.rescan()
        #expect(await hub.sessionInFront()?.id == Self.id("t1"))
        #expect(front.asked.last?.map(\.pid) == [4242])
    }

    @Test func aHostedConversationWithNoProcessIsNeverFocusedThroughATerminal() async {
        let host = FakeHost()
        host.opening = .unsupported
        host.conversations = [Self.thread("t1")]
        let focus = FakeFocus()
        let hub = makeHub(host, focus: focus)
        await hub.rescan()
        #expect(await hub.open(Self.id("t1")) == AgentFocusResult.none)
        #expect(focus.focused.isEmpty)
    }

    private func waiting(_ native: String, _ state: AgentLiveState) -> AgentSession {
        var session = Self.thread(native)
        session.state = state
        return session
    }

    private func settled(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aHostQueuingInTheHubHasAMessageHeldWhileItWaitsOnTheUserAndSentWhenItIsFree() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .waitingApproval)]
        let hub = makeHub(host)
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        #expect(await hub.deliver("run the tests", to: Self.id("t1"), request: "q1") == .queued(hub.directory.conversations[0].handle, waitingOn: .approval))
        #expect(host.delivered.isEmpty)
        host.conversations = [waiting("t1", .working)]
        host.watcher?(.listing)
        await hub.rescan()
        await settled { !notices.isEmpty }
        #expect(host.delivered.map(\.1) == ["q1"])
        #expect(notices == [.sent(hub.directory.conversations[0].handle)])
    }

    @Test func twoDictationsHeldInTheHubDuringAnApprovalBothArriveInOrder() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .waitingApproval)]
        let hub = makeHub(host)
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        _ = await hub.deliver("then the docs", to: Self.id("t1"), request: "q2")
        #expect(host.delivered.isEmpty)
        host.conversations = [waiting("t1", .working)]
        for _ in 0..<3 {
            host.watcher?(.listing)
            await hub.rescan()
            await settled { notices.count == 2 }
        }
        #expect(host.delivered.map(\.1) == ["q1", "q2"])
        #expect(notices == [.sent(hub.directory.conversations[0].handle), .sent(hub.directory.conversations[0].handle)])
    }

    @Test func aSecondHeldDictationWaitsWhileTheFirstIsStillBeingSent() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .waitingApproval)]
        let hub = makeHub(host, receiptTimeout: .seconds(5))
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        _ = await hub.deliver("then the docs", to: Self.id("t1"), request: "q2")
        host.gated = true
        host.conversations = [waiting("t1", .working)]
        host.watcher?(.listing)
        await hub.rescan()
        await settled { !host.delivered.isEmpty }
        host.watcher?(.listing)
        await hub.rescan()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(host.delivered.map(\.1) == ["q1"])
        host.openGate()
        await settled { notices.count == 2 }
        #expect(host.delivered.map(\.1) == ["q1", "q2"])
    }

    @Test func threeHeldDictationsLeaveOneAtATime() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .waitingApproval)]
        let hub = makeHub(host, receiptTimeout: .seconds(5))
        await hub.rescan()
        for (text, request) in [("one", "q1"), ("two", "q2"), ("three", "q3")] { _ = await hub.deliver(text, to: Self.id("t1"), request: request) }
        host.gated = true
        host.conversations = [waiting("t1", .working)]
        host.watcher?(.listing)
        await hub.rescan()
        await settled { host.delivered.count == 1 }
        host.passOne()
        await settled { host.delivered.count == 2 }
        try? await Task.sleep(for: .milliseconds(20))
        host.watcher?(.listing)
        await hub.rescan()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(host.delivered.map(\.1) == ["q1", "q2"])
        host.openGate()
        await settled { host.delivered.count == 3 }
        #expect(host.delivered.map(\.1) == ["q1", "q2", "q3"])
    }

    @Test func aSecondDictationWaitsBehindAFirstStillBeingSentStraightAway() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .working)]
        let hub = makeHub(host, receiptTimeout: .seconds(5))
        await hub.rescan()
        host.gated = true
        let first = Task { await hub.deliver("run the tests", to: Self.id("t1"), request: "q1") }
        await settled { host.delivered.count == 1 }
        guard case .queued = await hub.deliver("then the docs", to: Self.id("t1"), request: "q2") else {
            Issue.record("the second dictation went alongside the first")
            return
        }
        host.openGate()
        _ = await first.value
        await settled { host.delivered.count == 2 }
        #expect(host.delivered.map(\.1) == ["q1", "q2"])
    }

    @Test func aFreshDictationTheHostCannotTakeYetIsKeptForReviewWhenTheUserTypedWhileItWasBeingSent() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .working)]
        let hub = makeHub(host, receiptTimeout: .seconds(5))
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        host.gated = true
        host.replies = [.queued]
        let first = Task { await hub.deliver("run the tests", to: Self.id("t1"), request: "q1") }
        await settled { host.delivered.count == 1 }
        hub.handle(.typed(session: Self.id("t1")))
        host.openGate()
        guard case .queued = await first.value else { Issue.record("not held"); return }
        await settled { !notices.isEmpty }
        #expect(host.delivered.map(\.1) == ["q1"])
        #expect(notices == [.kept(hub.directory.conversations[0].handle, reason: .typedSince)])
    }

    @Test func aDictationTheHostCannotTakeYetAfterItsConversationWasDisconnectedIsNotSentLater() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .working)]
        let hub = makeHub(host, receiptTimeout: .seconds(5))
        await hub.rescan()
        host.gated = true
        host.replies = [.queued]
        let first = Task { await hub.deliver("run the tests", to: Self.id("t1"), request: "q1") }
        await settled { host.delivered.count == 1 }
        hub.disconnect(Self.id("t1"))
        host.openGate()
        #expect(await first.value == .notSent(hub.disconnected.first?.handle, reason: .disconnected))
        hub.reconnect(Self.id("t1"))
        host.watcher?(.listing)
        await hub.rescan()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(host.delivered.map(\.1) == ["q1"])
    }

    @Test func aDictationTheHostCannotTakeYetOutsideARunningTurnIsTriedAgainAtItsDeadlineWithoutAnotherEvent() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .idle)]
        let hub = makeHub(host)
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        host.replies = [.queued]
        guard case .queued = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1") else { Issue.record("not held"); return }
        await settled { !notices.isEmpty }
        #expect(host.delivered.map(\.1) == ["q1", "q1"])
        #expect(notices == [.sent(hub.directory.conversations[0].handle)])
    }

    @Test func aDictationTheHostNeverTakesOutsideARunningTurnIsReportedNotSentOnceItsTimeIsUp() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.delivery = .queued
        host.conversations = [waiting("t1", .idle)]
        let hub = makeHub(host, heldLimit: .milliseconds(200))
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        guard case .queued = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1") else { Issue.record("not held"); return }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(notices.isEmpty)
        await settled { !notices.isEmpty }
        let tries = host.delivered.count
        try? await Task.sleep(for: .milliseconds(100))
        #expect(host.delivered.count == tries)
        #expect(notices == [.notSent(hub.directory.conversations[0].handle, reason: .expired)])
    }

    @Test func aDictationARunningTurnKeepsRefusingWaitsForTheTurnToEndAndIsThenSent() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.delivery = .queued
        host.conversations = [waiting("t1", .working)]
        let hub = makeHub(host, heldLimit: .milliseconds(100))
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(notices.isEmpty)
        #expect(host.delivered.count <= 4)
        host.delivery = .accepted
        host.conversations = [waiting("t1", .idle)]
        host.watcher?(.listing)
        await hub.rescan()
        await settled { !notices.isEmpty }
        #expect(notices == [.sent(hub.directory.conversations[0].handle)])
    }

    @Test func eventsWhileARetryWaitsAddNoSecondRetry() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.delivery = .queued
        host.conversations = [waiting("t1", .idle)]
        let hub = makeHub(host, heldLimit: .seconds(30))
        await hub.rescan()
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        for _ in 0..<5 {
            host.watcher?(.listing)
            await hub.rescan()
            await settled { host.delivered.count > 1 }
        }
        #expect(host.delivered.count > 1)
        #expect(hub.retryWaiting == [Self.id("t1")])
    }

    @Test func aDictationHeldThroughALongTurnStillArrivesWhenTheHostRefusesItOnceMoreAsTheTurnEnds() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.replies = [.queued, .queued]
        host.conversations = [waiting("t1", .working)]
        let hub = makeHub(host, heldLimit: .milliseconds(100))
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        try? await Task.sleep(for: .milliseconds(250))
        host.conversations = [waiting("t1", .idle)]
        host.watcher?(.listing)
        await hub.rescan()
        await settled { !notices.isEmpty }
        #expect(host.delivered.map(\.1) == ["q1", "q1", "q1"])
        #expect(notices == [.sent(hub.directory.conversations[0].handle)])
    }

    @Test func aMessageMarkedWhileARetryWaitsOnItsDeadlineGoesToReviewAtOnce() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.replies = [.queued, .queued]
        host.conversations = [waiting("t1", .idle)]
        let hub = makeHub(host, receiptTimeout: .seconds(5), heldLimit: .seconds(60))
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        guard case .queued = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1") else { Issue.record("not held"); return }
        #expect(hub.retryWaiting == [Self.id("t1")])
        host.gated = true
        host.watcher?(.listing)
        await hub.rescan()
        await settled { host.delivered.count == 2 }
        hub.handle(.typed(session: Self.id("t1")))
        host.openGate()
        await settled { !notices.isEmpty }
        #expect(notices == [.kept(hub.directory.conversations[0].handle, reason: .typedSince)])
    }

    @Test func aNewDictationWaitsBehindAReleasedOneStillBeingSent() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .waitingApproval)]
        let hub = makeHub(host, receiptTimeout: .seconds(5))
        await hub.rescan()
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        host.gated = true
        host.conversations = [waiting("t1", .working)]
        host.watcher?(.listing)
        await hub.rescan()
        await settled { host.delivered.count == 1 }
        guard case .queued = await hub.deliver("then the docs", to: Self.id("t1"), request: "q2") else {
            Issue.record("the new dictation went ahead")
            return
        }
        #expect(host.delivered.map(\.1) == ["q1"])
        host.openGate()
        await settled { host.delivered.count == 2 }
        #expect(host.delivered.map(\.1) == ["q1", "q2"])
    }

    @Test func aReleasedDictationTheHostCannotTakeYetIsKeptForReviewWhenTheUserTypedWhileItWasBeingSent() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .waitingApproval)]
        let hub = makeHub(host, receiptTimeout: .seconds(5))
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        host.gated = true
        host.replies = [.queued]
        host.conversations = [waiting("t1", .working)]
        host.watcher?(.listing)
        await hub.rescan()
        await settled { host.delivered.count == 1 }
        hub.handle(.typed(session: Self.id("t1")))
        host.openGate()
        for _ in 0..<3 {
            host.watcher?(.listing)
            await hub.rescan()
            await settled { !notices.isEmpty }
        }
        #expect(host.delivered.map(\.1) == ["q1"])
        #expect(notices == [.kept(hub.directory.conversations[0].handle, reason: .typedSince)])
    }

    @Test func aPromptTheHostReportsAsTypedWhileTheHubHandlesItsTurnKeepsAHeldDictationForReview() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.reportsTurns = true
        host.conversations = [waiting("t1", .waitingApproval)]
        let hub = makeHub(host)
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        host.onObserve = { event in
            if case .turnStarted(let session, _, _) = event { host.watcher?(.event(.typed(session: session))) }
        }
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "u1", prompt: AgentPromptDigest.of("something typed")))
        host.conversations = [waiting("t1", .idle)]
        host.watcher?(.listing)
        await hub.rescan()
        await settled { !notices.isEmpty }
        #expect(host.delivered.isEmpty)
        #expect(notices == [.kept(hub.directory.conversations[0].handle, reason: .typedSince)])
    }

    @Test func aReleasedDictationTheHostCannotTakeYetStaysAheadOfLaterOnes() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .waitingApproval)]
        let hub = makeHub(host)
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        _ = await hub.deliver("then the docs", to: Self.id("t1"), request: "q2")
        host.replies = [.queued]
        host.conversations = [waiting("t1", .working)]
        for _ in 0..<4 {
            host.watcher?(.listing)
            await hub.rescan()
            await settled { notices.count == 2 }
        }
        #expect(host.delivered.map(\.1) == ["q1", "q1", "q2"])
    }

    @Test func aHeldDictationReleasedAsItsConversationIsDisconnectedIsNeverSent() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .waitingApproval)]
        let hub = makeHub(host)
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        hub.onChange = { [weak hub] in
            hub?.onChange = nil
            hub?.disconnect(Self.id("t1"))
        }
        host.conversations = [waiting("t1", .working)]
        host.watcher?(.listing)
        await hub.rescan()
        await settled { !notices.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(host.delivered.isEmpty)
        #expect(notices.count == 1)
        if case .notSent(_, reason: .disconnected) = notices.first {} else { Issue.record("not reported as disconnected: \(notices)") }
    }

    @Test func aHeldDictationWhoseHostIsTurnedOffIsReportedNotSentAndNeverSentLater() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .waitingApproval)]
        var allowed = true
        let hub = makeHub(host, allowed: { _ in allowed })
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        allowed = false
        host.conversations = [waiting("t1", .working)]
        host.watcher?(.listing)
        await hub.rescan()
        await settled { !notices.isEmpty }
        allowed = true
        host.watcher?(.listing)
        await hub.rescan()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(host.delivered.isEmpty)
        #expect(notices.count == 1)
        if case .notSent = notices.first {} else { Issue.record("not reported as not sent: \(notices)") }
    }

    @Test func aHeldDictationReleasedAsTheHubStopsIsNeverSent() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .waitingApproval)]
        let hub = makeHub(host)
        await hub.rescan()
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        hub.onChange = { [weak hub] in hub?.stop() }
        host.conversations = [waiting("t1", .working)]
        host.watcher?(.listing)
        await hub.rescan()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(host.delivered.isEmpty)
    }

    @Test func aHostQueuingInTheHubSendsAtOnceToAWorkingConversationSoItCanSteer() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .working)]
        let hub = makeHub(host)
        await hub.rescan()
        #expect(await hub.deliver("also the docs", to: Self.id("t1"), request: "q1") == .sent(hub.directory.conversations[0].handle))
        #expect(host.delivered.map(\.1) == ["q1"])
    }

    @Test func aHeldHostMessageThePromptTheUserTypedOvertakesIsKeptForReviewNeverSent() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .waitingQuestion)]
        let hub = makeHub(host)
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        hub.handle(.typed(session: Self.id("t1")))
        host.conversations = [waiting("t1", .idle)]
        host.watcher?(.listing)
        await hub.rescan()
        await settled { !notices.isEmpty }
        #expect(host.delivered.isEmpty)
        #expect(notices == [.kept(hub.directory.conversations[0].handle, reason: .typedSince)])
    }

    @Test func aHeldHostMessageWhoseTurnWasStoppedIsKeptForReviewNeverSent() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .waitingApproval)]
        let hub = makeHub(host)
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "aborted", answer: ""))
        host.conversations = [waiting("t1", .idle)]
        host.watcher?(.listing)
        await hub.rescan()
        await settled { !notices.isEmpty }
        #expect(host.delivered.isEmpty)
        #expect(notices == [.kept(hub.directory.conversations[0].handle, reason: .interrupted)])
    }

    @Test func aHeldHostMessageWhoseConversationIsGoneIsReportedNotSent() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.conversations = [waiting("t1", .waitingApproval)]
        let hub = makeHub(host)
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        host.conversations = []
        host.watcher?(.listing)
        await hub.rescan()
        await settled { !notices.isEmpty }
        #expect(host.delivered.isEmpty)
        #expect(notices.count == 1)
        if case .notSent(_, reason: .conversationEnded) = notices.first {} else { Issue.record("not reported as ended") }
    }

    @Test func aMessageTheHostCouldNotTakeYetGoesBackIntoTheHubsQueue() async {
        let host = FakeHost()
        host.queuesInHub = true
        host.replies = [.queued]
        host.conversations = [waiting("t1", .idle)]
        let hub = makeHub(host)
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        guard case .queued = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1") else {
            Issue.record("not queued")
            return
        }
        host.conversations = [waiting("t1", .working)]
        host.watcher?(.listing)
        await hub.rescan()
        await settled { !notices.isEmpty }
        #expect(host.delivered.map(\.1) == ["q1", "q1"])
        #expect(notices == [.sent(hub.directory.conversations[0].handle)])
    }

    @Test func anUncertainHostDeliveryTheHostLaterConfirmsIsReportedSentOnce() async {
        let host = FakeHost()
        host.delivery = .uncertain
        host.confirmation = true
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host, hostConfirmDelay: .milliseconds(20))
        await hub.rescan()
        var notices: [(AgentReceipt, String)] = []
        hub.onNotice = { receipt, request, _ in notices.append((receipt, request)) }
        #expect(await hub.deliver("run the tests", to: Self.id("t1"), request: "q1") == .uncertain(hub.directory.conversations[0].handle))
        await settled { !notices.isEmpty }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(host.confirmed == ["q1"])
        #expect(notices.map(\.0) == [.sent(hub.directory.conversations[0].handle)])
        #expect(notices.map(\.1) == ["q1"])
    }

    @Test func anUncertainHostDeliveryTheHostCannotConfirmStaysUncertain() async {
        let host = FakeHost()
        host.delivery = .uncertain
        host.confirmation = false
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host, hostConfirmDelay: .milliseconds(20))
        await hub.rescan()
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await hub.deliver("run the tests", to: Self.id("t1"), request: "q1")
        await settled { !host.confirmed.isEmpty }
        await Task.yield()
        withExtendedLifetime(hub) {
            #expect(host.confirmed == ["q1"])
            #expect(notices.isEmpty)
        }
    }

    @Test func aHostThatSaysItsListChangedIsAskedAgainAtOnceNotAfterTheFallbackInterval() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .idle)
        var working = Self.thread("t1")
        working.state = .working
        host.conversations = [working]
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .idle)
        host.watcher?(.listing)
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .working)
    }

    @Test func anEventAHostReportsIsFiledUnderItsConversation() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        host.watcher?(.event(.waiting(session: Self.location("t1").conversationKey, prompt: AgentPrompt(kind: "confirm", said: "may I?"))))
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .userDialog)
        #expect(host.observed.contains(.waiting(session: Self.location("t1").conversationKey, prompt: AgentPrompt(kind: "confirm", said: "may I?"))))
        host.watcher?(.event(.waiting(session: Self.location("t1").conversationKey, prompt: nil)))
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state != .userDialog)
    }

    @Test func aHostThatDoesNotReportTurnsLeavesTheReplyToADeliveryUnheard() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        var replies: [String] = []
        hub.onResult = { _, _, reply, _, _, _ in replies.append(reply) }
        _ = await hub.deliver("plan the release", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("plan the release")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "planned"))
        #expect(replies.isEmpty)
    }

    @Test func anUncertainNewConversationWhoseTurnArrivesIsReportedSent() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await startReady(host, transport: transport)
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        _ = await startAnswering(hub, transport, answer: nil)
        hub.handle(.turnStarted(session: Self.id("t2"), turn: "a", prompt: AgentPromptDigest.of("plan the release")))
        #expect(notices == [.sent("a new Example conversation")])
    }

    @Test func anAgentRunningInsideAHostedConversationIsFiledUnderItSoTheConversationIsListedOnceAndConnected() async throws {
        let hub = await joined(FakeHost())
        #expect(hub.directory.conversations.map(\.id) == [Self.id("t1")])
        let listed = try #require(hub.directory.conversations.first)
        #expect(listed.connectorLive)
        #expect(listed.host == Self.location("t1"))
    }

    @Test func anAgentIsFiledUnderAHostedConversationOnlyWhenTheHostIsOnAndListsIt() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let claude = FakeDiscovery(kind: .claude)
        claude.result = .found([Self.claudeSession(), Self.claudeSession("s2", pid: 43)])
        var turnedOn = true
        let hub = makeHub(
            host, allowed: { _ in turnedOn }, claude: claude,
            environments: [42: ["EXAMPLE_THREAD": "t9"], 43: ["EXAMPLE_THREAD": "t1"]])
        await hub.rescan()
        #expect(hub.filing(for: Self.hello("claude:s1")) == nil)
        #expect(hub.filing(for: Self.hello("claude:s9")) == nil)
        turnedOn = false
        await hub.rescan()
        #expect(hub.filing(for: Self.hello("claude:s2")) == nil)
        #expect(Set(hub.directory.conversations.map(\.id)) == ["claude:s1", "claude:s2"])
    }

    @Test func anAgentThatSaidHelloBeforeItsHostListedTheConversationIsAskedOnceToSayHelloAgain() async {
        let host = FakeHost()
        let claude = FakeDiscovery(kind: .claude)
        claude.result = .found([Self.claudeSession()])
        let transport = FakeTransport()
        transport.live = ["claude:s1"]
        var at = Date(timeIntervalSince1970: 1000)
        let hub = makeHub(host, transport: transport, claude: claude, environments: [42: ["EXAMPLE_THREAD": "t1"]], now: { at })
        await hub.rescan()
        #expect(transport.rehelloed.isEmpty)
        #expect(hub.directory.conversations.map(\.id) == ["claude:s1"])
        host.conversations = [Self.thread("t1")]
        at += HostDiscovery.idleInterval + 1
        await hub.rescan()
        #expect(hub.directory.conversations.map(\.id) == [Self.id("t1")])
        #expect(transport.rehelloed == ["claude:s1"])
        hub.refresh()
        #expect(transport.rehelloed == ["claude:s1"])
    }

    @Test func turningTheHostOffSendsAnAgentFiledUnderItBackToSayHelloAsItself() async {
        var turnedOn = true
        let transport = FakeTransport()
        let hub = await joined(FakeHost(), transport: transport, allowed: { _ in turnedOn })
        turnedOn = false
        await hub.rescan()
        #expect(transport.rehelloed == [Self.id("t1")])
        #expect(hub.filing(for: Self.hello("claude:s1")) == nil)
    }

    @Test(arguments: [AgentHostDelivery.accepted, .queued, .uncertain])
    func aDictationToAHostedConversationIsFollowedIntoTheTurnThatStartsWithItsTextAndNoOther(answer: AgentHostDelivery) async {
        let host = FakeHost()
        host.delivery = answer
        let hub = await joined(host)
        var results: [[String?]] = []
        hub.onResult = { conversation, handle, reply, requested, origin, _ in results.append([conversation, handle, reply, "\(requested)", origin]) }
        _ = await hub.deliver("say kiwi", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "typed", prompt: AgentPromptDigest.of("something the user typed")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "not ours"))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "system", prompt: nil))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "not ours either"))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "ours", prompt: AgentPromptDigest.of("say kiwi")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "kiwi"))
        #expect(results == [[Self.id("t1"), "docs", "kiwi", "false", "q1"]])
    }

    @Test func aDictationTheHostSteersIntoARunningTurnIsFollowedIntoThatTurn() async {
        let host = FakeHost()
        host.delivery = .accepted
        let hub = await joined(host)
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "running", prompt: AgentPromptDigest.of("the earlier work")))
        var results: [[String?]] = []
        hub.onResult = { _, _, reply, _, origin, _ in results.append([reply, origin]) }
        _ = await hub.deliver("use the other file", to: Self.id("t1"), request: "q1")
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "used it"))
        #expect(results == [["used it", "q1"]])
    }

    @Test func aDictationTheHostQueuesBehindARunningTurnIsNeverTakenForThatTurn() async {
        let host = FakeHost()
        host.delivery = .queued
        let hub = await joined(host)
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "running", prompt: AgentPromptDigest.of("the earlier work")))
        var origins: [String?] = []
        hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        _ = await hub.deliver("use the other file", to: Self.id("t1"), request: "q1")
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "the earlier answer"))
        #expect(!origins.contains("q1"))
    }

    @Test func twoDictationsWaitingInTheHostEachGetTheReplyToTheirOwnTurn() async {
        let host = FakeHost()
        host.delivery = .queued
        let hub = await joined(host)
        var origins: [String?] = []
        var replies: [String] = []
        hub.onResult = { _, _, reply, _, origin, _ in
            replies.append(reply)
            origins.append(origin)
        }
        _ = await hub.deliver("first", to: Self.id("t1"), request: "q1")
        _ = await hub.deliver("second", to: Self.id("t1"), request: "q2")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("first")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "one"))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "b", prompt: AgentPromptDigest.of("second")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "two"))
        #expect(replies == ["one", "two"])
        #expect(origins == ["q1", "q2"])
    }

    @Test func aDictationTheHostQueuesIsStillFollowedWhenItsTurnStartsLongAfterTheHandOffLimit() async throws {
        let host = FakeHost()
        host.delivery = .queued
        let hub = await joined(host, handOffLimit: .milliseconds(5))
        var replies: [String] = []
        hub.onResult = { _, _, reply, _, _, _ in replies.append(reply) }
        _ = await hub.deliver("later", to: Self.id("t1"), request: "q1")
        try await Task.sleep(for: .milliseconds(60))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("later")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "done"))
        #expect(replies == ["done"])
    }

    @Test func aTurnStartedWithTheTextOfARefusedDictationIsNotFollowed() async {
        let host = FakeHost()
        let hub = await joined(host)
        var replies: [String] = []
        hub.onResult = { _, _, reply, _, _, _ in replies.append(reply) }
        host.delivery = .refused("bb no longer has this thread.")
        host.whileDelivering = { hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("say kiwi"))) }
        _ = await hub.deliver("say kiwi", to: Self.id("t1"), request: "q1")
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "kiwi"))
        #expect(replies.isEmpty)
    }

    @Test func aTurnStartedBeforeTheHostAnswersIsFollowedWhenTheHostTakesTheDictation() async {
        let host = FakeHost()
        let hub = await joined(host)
        var replies: [String] = []
        hub.onResult = { _, _, reply, _, _, _ in replies.append(reply) }
        host.whileDelivering = { hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("say kiwi"))) }
        _ = await hub.deliver("say kiwi", to: Self.id("t1"), request: "q1")
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "kiwi"))
        #expect(replies == ["kiwi"])
    }

    @Test func aDictationIsNotFollowedThroughAnAgentWhoseConnectorCannotNameItsTurnsPrompt() async {
        let host = FakeHost()
        let hub = await joined(host, features: [])
        var replies: [String] = []
        hub.onResult = { _, _, reply, _, _, _ in replies.append(reply) }
        _ = await hub.deliver("say kiwi", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("say kiwi")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "kiwi"))
        #expect(replies.isEmpty)
    }

    static func hostHello(_ native: String) -> AgentEvent.Hello {
        AgentEvent.Hello(
            protocolVersion: 3, agent: "example", agentVersion: "", instance: "plugin/\(native)", session: id(native), pid: 0,
            features: ["promptDigest"], connection: "plugin", installation: "inst-2")
    }

    @Test func theHostsOwnConnectorHoldsItsConversationAndSendsBackAnAgentFiledThere() async {
        let transport = FakeTransport()
        let hub = await joined(FakeHost(), transport: transport)
        #expect(hub.filing(for: Self.hostHello("t1")) == nil)
        hub.handle(.hello(Self.hostHello("t1")))
        #expect(transport.rehelloed == [Self.id("t1")])
        #expect(hub.filing(for: Self.hello("claude:s1")) == nil)
        await hub.rescan()
        #expect(transport.rehelloed == [Self.id("t1")])
    }

    @Test func readAloudAskedThroughTheAgentsOwnConnectorFollowsTheTurnTheHostsConnectorReportsAndIsReadOnce() async {
        let transport = FakeTransport()
        var at = Date(timeIntervalSince1970: 1000)
        let hub = await joined(FakeHost(), transport: transport, now: { at })
        #expect(hub.filing(for: Self.hostHello("t1")) == nil)
        hub.handle(.hello(Self.hostHello("t1")))
        #expect(hub.filing(for: Self.hello("claude:s1")) == nil)
        transport.live.insert("claude:s1")
        hub.handle(.hello(Self.hello("claude:s1")))
        hub.speaks = { true }
        var results: [(String, String, Bool)] = []
        hub.onResult = { conversation, _, answer, requested, _, _ in results.append((conversation, answer, requested)) }
        var attention: [AgentAttention?] = []
        hub.onAttention = { _, _, wanted, _ in attention.append(wanted) }
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "p1", prompt: nil))
        #expect(hub.notify(session: "claude:s1", turn: "c1", on: true))
        #expect(hub.notify(session: Self.id("t1"), turn: "p1", on: true))
        at += 60
        await hub.rescan()
        #expect(!attention.contains(.disconnected))
        hub.handle(.turnComplete(session: "claude:s1", reason: "complete", answer: "from inside"))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "done"))
        await hub.rescan()
        #expect(results.map(\.0) == [Self.id("t1")])
        #expect(results.map(\.1) == ["done"])
        #expect(results.map(\.2) == [true])
    }

    static func pluginHello(_ native: String, turn: String? = nil, waiting: AgentPrompt? = nil) -> AgentEvent.Hello {
        var hello = hostHello(native)
        hello.features = ["promptDigest", "readiness", "notify"]
        hello.idle = turn == nil
        hello.turn = turn
        hello.waiting = waiting
        return hello
    }

    private func held(_ transport: FakeTransport, turn: String?) async -> AgentHub {
        let hub = await joined(FakeHost(), transport: transport)
        #expect(hub.filing(for: Self.pluginHello("t1", turn: turn)) == nil)
        hub.prepare(for: Self.pluginHello("t1", turn: turn))
        hub.handle(.hello(Self.pluginHello("t1", turn: turn)))
        #expect(hub.filing(for: Self.hello("claude:s1")) == nil)
        transport.live.insert("claude:s1")
        hub.handle(.hello(Self.hello("claude:s1")))
        hub.speaks = { true }
        return hub
    }

    @Test func aNameTheUserGivesAHostedConversationIsAlsoGivenToItsHost() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let claude = FakeDiscovery(kind: .claude)
        claude.result = .found([Self.claudeSession()])
        let hub = makeHub(host, names: AgentNameStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), claude: claude)
        await hub.rescan()
        let scansBefore = host.scans
        #expect(throws: Never.self) { try hub.rename(Self.id("t1"), to: "alpha") }
        #expect(throws: Never.self) { try hub.rename("claude:s1", to: "beta") }
        #expect(hub.handle(of: Self.id("t1")) == "alpha")
        for _ in 0..<50 where host.retitled.isEmpty || host.scans == scansBefore { await Task.yield() }
        #expect(host.retitled.map { "\($0.0.native)=\($0.1)" } == ["t1=alpha"])
        #expect(host.scans > scansBefore)
    }

    @Test(arguments: [
        (AgentLiveState.waitingApproval, AgentDeliveryDecision.QueueReason.approval), (.waitingQuestion, .question),
        (.userDialog, .userDialog), (.working, .working),
    ])
    func aMessageTheHostQueuedSaysWhatTheConversationWaitsOn(state: AgentLiveState, reason: AgentDeliveryDecision.QueueReason) async {
        let host = FakeHost()
        var thread = Self.thread("t1")
        thread.state = state
        host.conversations = [thread]
        host.delivery = .queued
        let hub = makeHub(host)
        await hub.rescan()
        let handle = hub.directory.conversations.first { $0.id == Self.id("t1") }?.handle ?? ""
        #expect(await hub.deliver("use the other file", to: Self.id("t1")) == .queued(handle, waitingOn: reason))
    }

    @Test(arguments: [
        (String?("confirm"), AgentDeliveryDecision.QueueReason.approval), ("select", .question), ("input", .question), ("editor", .question),
        ("custom", .userDialog), (nil, .userDialog),
    ])
    func aMessageTheHostQueuedBehindAReportedPromptSaysWhatKindOfPromptItWaitsOn(kind: String?, reason: AgentDeliveryDecision.QueueReason) async {
        let host = FakeHost()
        var thread = Self.thread("t1")
        thread.state = .waitingQuestion
        host.conversations = [thread]
        host.delivery = .queued
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(Self.hostHello("t1")))
        hub.handle(.waiting(session: Self.id("t1"), prompt: AgentPrompt(kind: kind, title: "Pick one")))
        await hub.rescan()
        let handle = hub.directory.conversations.first { $0.id == Self.id("t1") }?.handle ?? ""
        #expect(await hub.deliver("use the other file", to: Self.id("t1")) == .queued(handle, waitingOn: reason))
    }

    @Test func aHostedConversationWhosePluginShowsNamesIsToldItsName() async {
        let transport = FakeTransport()
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        var hello = Self.pluginHello("t1")
        hello.features.append("label")
        hub.prepare(for: hello)
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(hello))
        let handle = hub.directory.conversations.first { $0.id == Self.id("t1") }?.handle
        #expect(handle != nil)
        let told = transport.sent.compactMap { command, session -> String? in
            if case .status(_, let expected, let text) = command, session == Self.id("t1"), expected == Self.id("t1") { return text }
            return nil
        }
        #expect(told == ["\u{201C}\(handle ?? "")\u{201D}"])
    }

    @Test func aHostedConversationIsToldItsNewNameAsSoonAsItIsRenamed() async throws {
        let transport = FakeTransport()
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host, transport: transport, names: AgentNameStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        await hub.rescan()
        var hello = Self.pluginHello("t1")
        hello.features.append("label")
        hub.prepare(for: hello)
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(hello))
        try hub.rename(Self.id("t1"), to: "orange thread")
        let told = transport.sent.compactMap { command, session -> String? in
            if case .status(_, _, let text) = command, session == Self.id("t1") { return text }
            return nil
        }
        #expect(told.last == "\u{201C}orange thread\u{201D}")
    }

    @Test func readAloudAskedThroughTheAgentsOwnConnectorFollowsATurnTheAppOnlyLearnedFromTheHello() async {
        let transport = FakeTransport()
        let hub = await held(transport, turn: "p0")
        var results: [String] = []
        hub.onResult = { _, _, answer, _, _, _ in results.append(answer) }
        #expect(hub.notify(session: "claude:s1", turn: "c1", on: true))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "this one"))
        await hub.rescan()
        #expect(results == ["this one"])
    }

    @Test func readAloudAskedThroughTheAgentsOwnConnectorPromisesNothingWhileATurnItCannotNameRuns() async {
        let transport = FakeTransport()
        var hello = Self.pluginHello("t1")
        hello.idle = false
        let hub = await joined(FakeHost(), transport: transport)
        #expect(hub.filing(for: hello) == nil)
        hub.prepare(for: hello)
        hub.handle(.hello(hello))
        #expect(hub.filing(for: Self.hello("claude:s1")) == nil)
        transport.live.insert("claude:s1")
        hub.handle(.hello(Self.hello("claude:s1")))
        hub.speaks = { true }
        var results: [String] = []
        hub.onResult = { _, _, answer, _, _, _ in results.append(answer) }
        #expect(!hub.notify(session: "claude:s1", turn: "c1", on: true))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "p2", prompt: nil))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "a later turn"))
        await hub.rescan()
        #expect(results.isEmpty)
    }

    @Test func aPromisedReplySurvivesTheHostsConnectorSayingHelloAgainMidTurnAndIsReadOnce() async {
        let transport = FakeTransport()
        let hub = await held(transport, turn: nil)
        var results: [String] = []
        hub.onResult = { _, _, answer, _, _, _ in results.append(answer) }
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "p1", prompt: nil))
        #expect(hub.notify(session: Self.id("t1"), turn: "p1", on: true))
        let again = Self.pluginHello("t1", turn: "p1", waiting: AgentPrompt(kind: "confirm", detail: "make test"))
        hub.prepare(for: again)
        hub.handle(.hello(again))
        #expect(hub.notify(session: "claude:s1", turn: "c1", on: true))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "kept"))
        await hub.rescan()
        #expect(results == ["kept"])
    }

    @Test func aReplyFollowedByTheHostsConnectorSayingHelloIdleIsReadAndNeverReplacedByTheRepliedNotice() async {
        let transport = FakeTransport()
        let hub = await held(transport, turn: nil)
        var results: [String] = []
        var ended: [String] = []
        hub.onResult = { _, _, answer, _, _, _ in results.append(answer) }
        hub.onEnded = { _, _, body, _, _ in ended.append(body) }
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "p1", prompt: nil))
        #expect(hub.notify(session: Self.id("t1"), turn: "p1", on: true))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "the reply"))
        let again = Self.pluginHello("t1")
        hub.prepare(for: again)
        hub.handle(.hello(again))
        await hub.rescan()
        #expect(results == ["the reply"])
        #expect(ended.isEmpty)
    }

    @Test func readAloudAskedThroughTheAgentsOwnConnectorBetweenTheHostsTurnsWaitsForItsNextTurn() async {
        let transport = FakeTransport()
        let hub = await joined(FakeHost(), transport: transport)
        #expect(hub.filing(for: Self.hostHello("t1")) == nil)
        hub.handle(.hello(Self.hostHello("t1")))
        #expect(hub.filing(for: Self.hello("claude:s1")) == nil)
        transport.live.insert("claude:s1")
        hub.handle(.hello(Self.hello("claude:s1")))
        hub.speaks = { true }
        var results: [String] = []
        hub.onResult = { conversation, _, _, _, _, _ in results.append(conversation) }
        #expect(hub.notify(session: "claude:s1", turn: "c1", on: true))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "p2", prompt: nil))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "next"))
        await hub.rescan()
        #expect(results == [Self.id("t1")])
    }

    @Test func anAgentIsFiledUnderItsHostedConversationAgainOnceTheHostsOwnConnectorStops() async {
        let transport = FakeTransport()
        let hub = await joined(FakeHost(), transport: transport)
        #expect(hub.filing(for: Self.hostHello("t1")) == nil)
        hub.handle(.hello(Self.hostHello("t1")))
        #expect(hub.filing(for: Self.hello("claude:s1")) == nil)
        transport.live = ["claude:s1"]
        await hub.rescan()
        #expect(transport.rehelloed == [Self.id("t1"), "claude:s1"])
        #expect(hub.filing(for: Self.hello("claude:s1")) == Self.id("t1"))
    }

    @Test func aConversationTheHostsOwnConnectorHoldsStillSaysItNeedsYouFromTheHostsOwnList() async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let transport = FakeTransport()
        var at = Date(timeIntervalSince1970: 1000)
        let hub = makeHub(host, transport: transport, now: { at })
        await hub.rescan()
        #expect(hub.filing(for: Self.hostHello("t1")) == nil)
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(Self.hostHello("t1")))
        #expect(hub.directory.conversations.map(\.id) == [Self.id("t1")])
        #expect(hub.directory.conversations.first?.connectorLive == true)
        var attention: [AgentAttention?] = []
        hub.onAttention = { _, _, wanted, _ in attention.append(wanted) }
        _ = await hub.deliver("run the migration", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("run the migration")))
        var waiting = Self.thread("t1")
        waiting.state = .waitingQuestion
        host.conversations = [waiting]
        at += HostDiscovery.fallbackInterval + 1
        await hub.rescan(wantingHosts: true)
        #expect(hub.directory.conversations.first?.state == .waitingQuestion)
        #expect(attention.last == .question)
    }

    @Test func aPromptTheHostsOwnConnectorReportsIsDescribedLikeAnAgentsOwnAndEndsWithIt() async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let transport = FakeTransport()
        var at = Date(timeIntervalSince1970: 1000)
        let hub = makeHub(host, transport: transport, now: { at })
        await hub.rescan()
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(Self.hostHello("t1")))
        var attention: [AgentAttention?] = []
        hub.onAttention = { _, _, wanted, _ in attention.append(wanted) }
        _ = await hub.deliver("run the migration", to: Self.id("t1"), request: "q1")
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("run the migration")))
        var asking = Self.thread("t1")
        asking.state = .waitingQuestion
        host.conversations = [asking]
        at += HostDiscovery.fallbackInterval + 1
        await hub.rescan(wantingHosts: true)
        let scans = host.scans
        let prompt = AgentPrompt(kind: "confirm", title: "Run the tests", tool: "command", detail: "make test")
        hub.handle(.waiting(session: Self.id("t1"), prompt: prompt))
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .userDialog)
        #expect(attention.last == .waiting(prompt))
        hub.handle(.waiting(session: Self.id("t1"), prompt: nil))
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .working)
        #expect(attention.last == .some(nil))
        #expect(host.scans == scans)
        host.conversations = [Self.thread("t1")]
        at += HostDiscovery.fallbackInterval + 1
        await hub.rescan(wantingHosts: true)
        #expect(hub.directory.conversations.first?.state == .idle)
    }

    @Test func aTurnTheHostsOwnConnectorReportsShowsAtOnceUntilANewerHostListSaysOtherwise() async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let transport = FakeTransport()
        var at = Date(timeIntervalSince1970: 1000)
        let hub = makeHub(host, transport: transport, now: { at })
        await hub.rescan()
        transport.live.insert(Self.id("t1"))
        var hello = Self.hostHello("t1")
        hello.features = ["promptDigest", "readiness", "notify"]
        hello.idle = true
        hub.handle(.hello(hello))
        await hub.rescan()
        let scans = host.scans
        at += 1
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a"))
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .working)
        #expect(host.scans == scans)
        var working = Self.thread("t1")
        working.state = .working
        host.conversations = [working]
        at += HostDiscovery.fallbackInterval + 1
        await hub.rescan(wantingHosts: true)
        #expect(hub.directory.conversations.first?.state == .working)
        let listed = host.scans
        at += 1
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "done"))
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .idle)
        #expect(host.scans == listed)
        at += HostDiscovery.fallbackInterval + 1
        await hub.rescan(wantingHosts: true)
        #expect(hub.directory.conversations.first?.state == .working)
    }

    @Test func aTurnFromAConnectorThatDoesNotReportTurnsLeavesTheHostsListStanding() async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(Self.hostHello("t1")))
        await hub.rescan()
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a"))
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .idle)
    }

    @Test func aTurnThatEndsWhileItsPromptWasOpenReadsAsIdleNotAsWorking() async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        transport.live.insert(Self.id("t1"))
        var hello = Self.hostHello("t1")
        hello.features = ["promptDigest", "readiness", "notify"]
        hello.idle = false
        hub.handle(.hello(hello))
        hub.handle(.waiting(session: Self.id("t1"), prompt: AgentPrompt(kind: "confirm", detail: "make test")))
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .userDialog)
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "done"))
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .idle)
    }

    @Test func aHostListReadAfterThePromptOpenedThatShowsTheThreadIdleEndsAPromptWhoseClearWasLost() async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let transport = FakeTransport()
        var at = Date(timeIntervalSince1970: 1000)
        let hub = makeHub(host, transport: transport, now: { at })
        await hub.rescan()
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(Self.hostHello("t1")))
        hub.handle(.waiting(session: Self.id("t1"), prompt: AgentPrompt(kind: "confirm", detail: "make test")))
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .userDialog)
        var working = Self.thread("t1")
        working.state = .working
        host.conversations = [working]
        at += HostDiscovery.fallbackInterval + 1
        await hub.rescan(wantingHosts: true)
        #expect(hub.directory.conversations.first?.state == .userDialog)
        host.conversations = [Self.thread("t1")]
        at += HostDiscovery.fallbackInterval + 1
        await hub.rescan(wantingHosts: true)
        #expect(hub.directory.conversations.first?.state == .idle)
    }

    @Test func theHostsOwnConnectorGreetingForAConversationTheHostHasNotListedHasTheHostAskedOnce() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        let scans = host.scans
        host.conversations = [Self.thread("t1")]
        transport.live.insert(Self.id("t1"))
        hub.handle(.hello(Self.hostHello("t1")))
        await hub.rescan()
        #expect(host.scans == scans + 1)
        #expect(hub.directory.conversations.map(\.id) == [Self.id("t1")])
        hub.handle(.hello(Self.hostHello("t1")))
        await hub.rescan()
        #expect(host.scans == scans + 1)
        hub.handle(.hello(Self.hostHello("t2")))
        await hub.rescan()
        hub.handle(.hello(Self.hostHello("t2")))
        await hub.rescan()
        #expect(host.scans == scans + 2)
    }

    @Test func aPromptStillOpenWhenTheHostsOwnConnectorSaysHelloAgainKeepsTheConversationWaitingOnIt() async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let transport = FakeTransport()
        let hub = makeHub(host, transport: transport)
        await hub.rescan()
        transport.live.insert(Self.id("t1"))
        var hello = Self.hostHello("t1")
        hello.waiting = AgentPrompt(kind: "select", title: "Which branch?")
        hub.handle(.hello(hello))
        await hub.rescan()
        #expect(hub.directory.conversations.first?.state == .userDialog)
    }

    @Test func whileItsHostIsOffTheHostsOwnConnectorIsAnsweredQuietly() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let transport = FakeTransport()
        var on = false
        var at = Date(timeIntervalSince1970: 1000)
        let hub = makeHub(host, transport: transport, allowed: { _ in on }, now: { at })
        #expect(transport.silenced == [["example"]])
        await hub.rescan()
        #expect(transport.silenced == [["example"]])
        on = true
        at += HostDiscovery.fallbackInterval + 1
        await hub.rescan(wantingHosts: true)
        #expect(transport.silenced == [["example"], []])
        on = false
        await hub.rescan()
        #expect(transport.silenced == [["example"], [], ["example"]])
        _ = hub
    }

    @Test func theHostsOwnConnectorIsNeverComparedWithTheVersionOfTheAgentRunningInTheConversation() async {
        let hub = await joined(FakeHost())
        hub.bundledVersion = { _ in "0.2.0" }
        var hello = Self.hostHello("t1")
        hello.codeVersion = "0.1.0-plugin"
        #expect(hub.filing(for: hello) == nil)
        hub.handle(.hello(hello))
        #expect(hub.olderConnectors.isEmpty)
    }

    @Test func theHostsOwnConnectorHoldsNothingForAConversationItsHostDoesNotList() async {
        let transport = FakeTransport()
        let hub = await joined(FakeHost(), transport: transport)
        #expect(hub.filing(for: Self.hostHello("t9")) == nil)
        #expect(transport.rehelloed.isEmpty)
        #expect(hub.filing(for: Self.hello("claude:s1")) == Self.id("t1"))
    }

    @Test func theSameConnectorSayingHelloAsANewSessionStaysFiledUnderItsConversation() async {
        let claude = FakeDiscovery(kind: .claude)
        let hub = await joined(FakeHost(), claude: claude)
        claude.result = .found([Self.claudeSession("s2", pid: 42)])
        await hub.rescan()
        #expect(hub.filing(for: Self.hello("claude:s2")) == Self.id("t1"))
        var elsewhere = Self.hello("claude:s3")
        elsewhere.instance = "i9"
        claude.result = .found([Self.claudeSession("s2", pid: 42), Self.claudeSession("s3", pid: 42)])
        await hub.rescan()
        #expect(hub.filing(for: elsewhere) == nil)
    }

    @Test func onlyTheAgentTheHostStartedIsPlacedInItsConversationNeverOneThatAgentStarted() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let claude = FakeDiscovery(kind: .claude)
        claude.result = .found([Self.claudeSession(), Self.claudeSession("s2", pid: 43)])
        let thread = ["EXAMPLE_THREAD": "t1"]
        let hub = makeHub(host, claude: claude, environments: [42: thread, 43: thread], parents: [42: 1, 43: 42])
        await hub.rescan()
        #expect(Set(hub.directory.conversations.map(\.id)) == [Self.id("t1"), "claude:s2"])
        #expect(hub.filing(for: Self.hello("claude:s2")) == nil)
        #expect(hub.filing(for: Self.hello("claude:s1")) == Self.id("t1"))
    }

    @Test func aDisconnectANameAndTheCurrentChoiceFollowTheConversationIntoItsHostAndBack() async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1"), Self.thread("t2", cwd: "/src/site")]
        let claude = FakeDiscovery(kind: .claude)
        claude.result = .found([Self.claudeSession(), Self.claudeSession("s2", pid: 43)])
        var turnedOn = false
        let hub = makeHub(
            host, allowed: { _ in turnedOn }, claude: claude,
            environments: [42: ["EXAMPLE_THREAD": "t1"], 43: ["EXAMPLE_THREAD": "t2"]])
        hub.exclusions.adopt([])
        await hub.rescan()
        try hub.rename("claude:s1", to: "billing")
        hub.disconnect("claude:s2")
        turnedOn = true
        await hub.rescan(wantingHosts: true)
        #expect(hub.directory.conversations.first { $0.id == Self.id("t1") }?.handle == "billing")
        #expect(hub.isExcluded(Self.id("t2")))
        #expect(!hub.directory.conversations.contains { $0.id == Self.id("t2") })
        turnedOn = false
        await hub.rescan()
        #expect(hub.isExcluded("claude:s2"))
        #expect(hub.directory.conversations.first { $0.id == "claude:s1" }?.handle == "billing")
    }

    @Test func reconnectingTheHostedConversationAlsoReconnectsTheAgentInsideIt() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let claude = FakeDiscovery(kind: .claude)
        claude.result = .found([Self.claudeSession()])
        var turnedOn = false
        let hub = makeHub(host, allowed: { _ in turnedOn }, claude: claude, environments: [42: ["EXAMPLE_THREAD": "t1"]])
        hub.exclusions.adopt([])
        await hub.rescan()
        hub.disconnect("claude:s1")
        turnedOn = true
        await hub.rescan(wantingHosts: true)
        hub.reconnect(Self.id("t1"))
        turnedOn = false
        await hub.rescan()
        #expect(!hub.isExcluded("claude:s1"))
    }

    @Test func theRowOfAHostedConversationAnAgentRunsInKeepsThatAgentAndItsSetup() async throws {
        let claude = FakeDiscovery(kind: .claude)
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        var session = Self.claudeSession()
        session.setup = "/Users/a/.claude"
        claude.result = .found([session])
        let hub = makeHub(host, claude: claude, environments: [42: ["EXAMPLE_THREAD": "t1"]])
        await hub.rescan()
        let row = try #require(hub.directory.conversations.first)
        #expect(row.id == Self.id("t1"))
        #expect(row.runningAgent == "claude")
        #expect(row.setup == "/Users/a/.claude")
        #expect(hub.kind(of: Self.id("t1")) == .claude)
    }

    @Test func anAgentPlacedInAConversationItsHostDoesNotListYetHasTheHostAskedAtOnceButOnlyOnce() async throws {
        let host = FakeHost()
        let claude = FakeDiscovery(kind: .claude)
        claude.result = .found([Self.claudeSession()])
        let hub = makeHub(host, claude: claude, environments: [42: ["EXAMPLE_THREAD": "t1"]])
        await hub.rescan()
        host.conversations = [Self.thread("t1")]
        for _ in 0..<50 where hub.directory.conversations.map(\.id) != [Self.id("t1")] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hub.directory.conversations.map(\.id) == [Self.id("t1")])
        let scans = host.scans
        #expect(hub.filing(for: Self.hello("claude:s1")) == Self.id("t1"))
        await hub.rescan()
        #expect(host.scans == scans)
    }

    @Test func aDictationTheHostTookAtOnceStopsBeingFollowedIfNoTurnCarriesItInTime() async {
        var at = Date(timeIntervalSince1970: 1000)
        let host = FakeHost()
        let hub = await joined(host, now: { at })
        var replies: [String] = []
        hub.onResult = { _, _, reply, _, _, _ in replies.append(reply) }
        _ = await hub.deliver("continue", to: Self.id("t1"), request: "q1")
        host.delivery = .queued
        _ = await hub.deliver("later", to: Self.id("t1"), request: "q2")
        at += AgentHub.hostTurnWait + 1
        hub.refresh()
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("continue")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "typed again much later"))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "b", prompt: AgentPromptDigest.of("later")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "queued reply"))
        #expect(replies == ["queued reply"])
    }

    @Test func aReplyThatCompletesBeforeTheHostRefusesTheDictationIsNeverSpoken() async {
        let host = FakeHost()
        let hub = await joined(host)
        var replies: [String] = []
        hub.onResult = { _, _, reply, _, _, _ in replies.append(reply) }
        host.delivery = .refused("bb did not take it.")
        host.whileDelivering = {
            hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("say kiwi")))
            hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "kiwi"))
        }
        _ = await hub.deliver("say kiwi", to: Self.id("t1"), request: "q1")
        #expect(replies.isEmpty)
        host.delivery = .accepted
        _ = await hub.deliver("say kiwi", to: Self.id("t1"), request: "q2")
        #expect(replies == ["kiwi"])
    }

    @Test func anUncertainJoinIsRecordedAsSentWithTheTypedTextOnceItsOwnTurnStarts() async {
        let host = FakeHost()
        let transport = FakeTransport()
        let hub = await pluginJoined(host, transport: transport)
        var notices: [AgentReceipt] = []
        hub.onNotice = { receipt, _, _ in notices.append(receipt) }
        #expect(await deliverAnswering(hub, transport, answer: nil) == .uncertain("docs"))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("run the tests")))
        #expect(notices == [.sentWithDraft("docs")])
    }

    @Test func anUncertainDictationIsRecordedAsSentOnceItsOwnTurnStarts() async {
        let host = FakeHost()
        host.delivery = .uncertain
        let hub = await joined(host)
        var notices: [(AgentReceipt, String)] = []
        hub.onNotice = { receipt, request, _ in notices.append((receipt, request)) }
        #expect(await hub.deliver("say kiwi", to: Self.id("t1"), request: "q1") == .uncertain("docs"))
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("say kiwi")))
        #expect(notices.map(\.0) == [.sent("docs")])
        #expect(notices.map(\.1) == ["q1"])
        host.whileDelivering = { hub.handle(.turnStarted(session: Self.id("t1"), turn: "b", prompt: AgentPromptDigest.of("again"))) }
        #expect(await hub.deliver("again", to: Self.id("t1"), request: "q2") == .sent("docs"))
    }

    @Test func reconnectingTheAgentAfterItLeftItsHostAlsoReconnectsTheHostedConversation() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let claude = FakeDiscovery(kind: .claude)
        claude.result = .found([Self.claudeSession()])
        var turnedOn = true
        let hub = makeHub(host, allowed: { _ in turnedOn }, claude: claude, environments: [42: ["EXAMPLE_THREAD": "t1"]])
        hub.exclusions.adopt([])
        await hub.rescan()
        hub.disconnect(Self.id("t1"))
        turnedOn = false
        await hub.rescan()
        #expect(hub.isExcluded("claude:s1"))
        hub.reconnect("claude:s1")
        turnedOn = true
        await hub.rescan(wantingHosts: true)
        #expect(!hub.isExcluded(Self.id("t1")))
        #expect(hub.directory.conversations.map(\.id) == [Self.id("t1")])
    }

    @Test(arguments: [AgentLiveState.waitingApproval, .userDialog, .waitingQuestion, .working])
    func aHostedConversationShowsTheStateOfTheAgentRunningInsideIt(state: AgentLiveState) async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let claude = FakeDiscovery(kind: .claude)
        var session = Self.claudeSession()
        session.state = state
        claude.result = .found([session])
        let hub = makeHub(host, claude: claude, environments: [42: ["EXAMPLE_THREAD": "t1"]])
        await hub.rescan()
        #expect(try #require(hub.directory.conversations.first).state == state)
    }

    @Test func aReplyHeldWhileTheHostAnswersIsDroppedWhenTheConversationIsDisconnectedMeanwhile() async {
        let host = FakeHost()
        let hub = await joined(host)
        hub.exclusions.adopt([])
        var replies: [String] = []
        hub.onResult = { _, _, reply, _, _, _ in replies.append(reply) }
        host.whileDelivering = {
            hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("say kiwi")))
            hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "kiwi"))
            hub.disconnect(Self.id("t1"))
        }
        _ = await hub.deliver("say kiwi", to: Self.id("t1"), request: "q1")
        #expect(replies.isEmpty)
    }

    @Test func aDictationPastItsWaitIsNotMatchedEvenBeforeTheListIsRefreshed() async {
        var at = Date(timeIntervalSince1970: 1000)
        let host = FakeHost()
        let hub = await joined(host, now: { at })
        var replies: [String] = []
        hub.onResult = { _, _, reply, _, _, _ in replies.append(reply) }
        _ = await hub.deliver("continue", to: Self.id("t1"), request: "q1")
        at += AgentHub.hostTurnWait + 1
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("continue")))
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "typed again much later"))
        #expect(replies.isEmpty)
    }

    @Test func eventsFromAConnectorFiledUnderAHostedConversationStillReachItsOwnAgentUnderItsOwnSession() async {
        let claude = FakeDiscovery(kind: .claude)
        let hub = await joined(FakeHost(), claude: claude)
        hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: "p"))
        hub.handle(.waiting(session: Self.id("t1"), prompt: AgentPrompt(title: "Allow?")))
        #expect(claude.observed.suffix(2) == [
            .turnStarted(session: "s1", turn: "a", prompt: "p"), .waiting(session: "s1", prompt: AgentPrompt(title: "Allow?")),
        ])
    }

    @Test func aClipboardImageReachesAHostedConversationAttachedWithItsPathStillInTheText() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        let text = "look at /tmp/clip.png"
        #expect(await hub.deliver(text, to: Self.id("t1"), images: ["/tmp/clip.png"]) == .sent("docs"))
        #expect(host.delivered.map(\.0) == [text])
        #expect(host.deliveredImages == [["/tmp/clip.png"]])
        #expect(hub.takesImages(Self.id("t1")))
        let note = AgentOutput.ClipboardNote(images: 1, files: 0, attached: hub.takesImages(Self.id("t1")))
        #expect(AgentOutput.receiptState(.sent("docs"), mode: "Agent", heard: "", clipboard: note)
            == .commandDone(summary: "Sent to docs with 1 image", detail: "Agent"))
    }

    @Test func aHostThatTakesNoImagesIsSaidToSendOnlyThePath() async {
        let host = FakeHost()
        host.takesImages = false
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        #expect(!hub.takesImages(Self.id("t1")))
    }

    @Test func aHostTurnedOffBeforeDeliveryIsNotUsedAndTheSendSaysSo() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        host.isEnabled = false
        #expect(await hub.deliver("fix the test", to: Self.id("t1")) == .notSent("docs", reason: .connectorNotRunning))
        #expect(host.delivered.isEmpty)
    }

    @Test func aHostThatDoesNotAnswerInTimeLeavesDeliveryUncertainAndOpenAndFrontUnanswered() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        host.front = .shown(Self.location("t1"), in: AgentHostApp(bundle: "dev.example.app", pid: 50, name: "Example"))
        let hub = makeHub(host)
        await hub.rescan()
        host.hangs = true
        let waits = RequestedWaits()
        hub.sleep = { await waits.record($0); try await Task.sleep(for: $0) }
        let started = ContinuousClock.now
        #expect(await hub.deliver("fix the test", to: Self.id("t1")) == .uncertain("docs"))
        #expect(await hub.open(Self.id("t1")) == .refused("Example didn\u{2019}t answer in time."))
        #expect(await hub.sessionInFront() == nil)
        let requested = await waits.all
        #expect(requested.count >= 3)
        #expect(Set(requested) == [.milliseconds(50)])
        #expect(ContinuousClock.now - started < .seconds(30))
        #expect(host.delivered.count == 1)
    }

    @Test func theSameThreadIdOnTwoInstancesIsTwoConversationsEachDeliveredToItsOwnInstance() async {
        let host = FakeHost()
        let other = "http://127.0.0.1:10"
        host.conversations = [Self.thread("t1"), Self.thread("t1", cwd: "/src/site", instance: other)]
        let hub = makeHub(host)
        await hub.rescan()
        #expect(Set(hub.directory.conversations.map(\.id)) == [Self.id("t1"), Self.id("t1", instance: other)])
        #expect(Set(hub.directory.conversations.map(\.handle)) == ["docs", "site"])
        _ = await hub.deliver("one", to: Self.id("t1", instance: other))
        _ = await hub.deliver("two", to: Self.id("t1"))
        #expect(host.delivered.map(\.0) == ["one", "two"])
        #expect(host.delivered.map(\.2.instance) == [other, Self.instance])
    }

    @Test func aTitleTheHostShowsNamesItsConversationLikeAPaneTitleAndAFailedListKeepsIt() async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        var clock = Date(timeIntervalSince1970: 1000)
        let hub = makeHub(host, now: { clock })
        await hub.rescan()
        #expect(hub.names == ["docs": Self.id("t1")])
        host.titles = ["t1": "release notes"]
        clock = clock.addingTimeInterval(HostDiscovery.idleInterval)
        await hub.rescan()
        #expect(hub.names == ["release notes": Self.id("t1")])
        host.answers = false
        clock = clock.addingTimeInterval(HostDiscovery.idleInterval)
        await hub.rescan()
        #expect(hub.names == ["release notes": Self.id("t1")])
    }

    @Test func aTitleTheHostClearsGivesTheConversationBackItsFolderNameEvenWithAPlaceReader() async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        host.titles = ["t1": "release notes"]
        var clock = Date(timeIntervalSince1970: 1000)
        let hub = makeHub(host, places: AgentPlaceTrackerTests.Reader(), now: { clock })
        await hub.rescan()
        #expect(hub.names == ["release notes": Self.id("t1")])
        let place = try #require(hub.directory.conversations.first?.placeName)
        #expect(place.surface == "Example")
        #expect(place.word == "title")
        host.titles = [:]
        clock = clock.addingTimeInterval(HostDiscovery.idleInterval)
        await hub.rescan()
        #expect(hub.names == ["docs": Self.id("t1")])
    }

    @Test func whatTheHostShowsInPlaceOfATitleNeverNamesTheConversationButStillReachesItAfterAVerb() async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        host.shownInstead = ["t1": "what time is it?"]
        let hub = makeHub(host)
        await hub.rescan()
        #expect(hub.names == ["docs": Self.id("t1")])
        let listed = try #require(hub.directory.conversations.first)
        #expect(listed.otherNames == ["what time is it"])
        #expect(listed.placeName == nil)
    }

    @Test func aTitleTheHostShowsStillReachesAConversationTheUserNamedWhenSaidAfterAVerb() async throws {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        host.titles = ["t1": "release notes"]
        let hub = makeHub(host)
        await hub.rescan()
        try hub.rename(Self.id("t1"), to: "scratch")
        await hub.rescan()
        let listed = try #require(hub.directory.conversations.first)
        #expect(listed.handle == "scratch")
        #expect(listed.otherNames == ["release notes"])
    }

    @Test func aHostedConversationsNameSurvivesARestartEvenWhenTheListIsRefreshedBeforeTheHostAnswers() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-host-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = FakeHost()
        host.conversations = [Self.thread("t1", startedAt: 100), Self.thread("t2", startedAt: 200)]
        let first = makeHub(host, names: AgentNameStore(directory: dir))
        await first.rescan()
        #expect(first.names == ["docs": Self.id("t1"), "docs blue": Self.id("t2")])

        let restarted = FakeHost()
        restarted.answers = false
        restarted.conversations = [Self.thread("t2", startedAt: 200)]
        var clock = Date(timeIntervalSince1970: 1000)
        let second = makeHub(restarted, names: AgentNameStore(directory: dir), now: { clock })
        second.refresh()
        await second.rescan()
        restarted.answers = true
        clock = clock.addingTimeInterval(HostDiscovery.fallbackInterval)
        await second.rescan(rereadingTitles: false)
        #expect(second.names == ["docs blue": Self.id("t2")])
    }

    @Test func hostedNamesSurviveTurningTheHostOffAndOnEvenWhenTheListIsRefreshedBeforeItAnswers() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-host-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = FakeHost()
        host.conversations = [Self.thread("t1", startedAt: 100), Self.thread("t2", startedAt: 200)]
        var turnedOn = true
        let hub = makeHub(host, names: AgentNameStore(directory: dir), allowed: { _ in turnedOn })
        await hub.rescan()
        #expect(hub.names == ["docs": Self.id("t1"), "docs blue": Self.id("t2")])
        turnedOn = false
        await hub.rescan(rereadingTitles: true)
        #expect(hub.names.isEmpty)
        turnedOn = true
        hub.refresh()

        let restarted = FakeHost()
        restarted.conversations = [Self.thread("t2", startedAt: 200)]
        let second = makeHub(restarted, names: AgentNameStore(directory: dir))
        await second.rescan()
        #expect(second.names == ["docs blue": Self.id("t2")])
    }

    @Test func theHostIsAskedForItsConversationsWhenTheUserNeedsThemAndOtherwiseOnlyAfterTheIdleInterval() async {
        let host = FakeHost()
        var clock = Date(timeIntervalSince1970: 1000)
        let hub = makeHub(host, now: { clock })
        await hub.rescan(rereadingTitles: false)
        await hub.rescan(rereadingTitles: true)
        #expect(host.scans == 1)
        clock = clock.addingTimeInterval(HostDiscovery.fallbackInterval)
        await hub.rescan(rereadingTitles: true)
        #expect(host.scans == 1)
        await hub.rescan(rereadingTitles: false, wantingHosts: true)
        #expect(host.scans == 2)
        await hub.rescan(rereadingTitles: false, wantingHosts: true)
        #expect(host.scans == 2)
        clock = clock.addingTimeInterval(HostDiscovery.idleInterval)
        await hub.rescan(rereadingTitles: false)
        #expect(host.scans == 3)
    }

    @Test func aHostThatCouldNotListIsAskedAgainAfterTheFallbackIntervalNotTheIdleOne() async {
        let host = FakeHost()
        host.answers = false
        var clock = Date(timeIntervalSince1970: 1000)
        let hub = makeHub(host, now: { clock })
        await hub.rescan(rereadingTitles: false)
        await hub.rescan(rereadingTitles: false)
        #expect(host.scans == 1)
        clock = clock.addingTimeInterval(HostDiscovery.fallbackInterval)
        await hub.rescan(rereadingTitles: false)
        #expect(host.scans == 2)
    }

    @Test func aPressAsksAnEnabledHostForItsConversationsAndNoHostMeansNoScan() async {
        let host = FakeHost()
        var clock = Date(timeIntervalSince1970: 1000)
        var turnedOn = true
        let hub = makeHub(host, allowed: { _ in turnedOn }, now: { clock })
        await hub.rescan()
        clock = clock.addingTimeInterval(HostDiscovery.fallbackInterval)
        await hub.refreshHostsForPress()
        #expect(host.scans == 2)
        turnedOn = false
        clock = clock.addingTimeInterval(HostDiscovery.fallbackInterval)
        await hub.refreshHostsForPress()
        #expect(host.scans == 2)
    }

    @Test func openPassesOnWhetherItIsStillWantedSoTheHostCanStopBeforeShowingAnything() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        var asked = 0
        _ = await hub.open(Self.id("t1"), stillWanted: {
            asked += 1
            return asked == 1
        })
        #expect(host.openSawWanted == [false])
    }

    @Test func cancellingAnOpenWhileTheHostIsWorkingCancelsTheHostsWorkAndReturnsAtOnce() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host, hostDeadline: .seconds(30))
        await hub.rescan()
        host.hangs = true
        let started = ContinuousClock.now
        let open = Task { await hub.open(Self.id("t1")) }
        try? await Task.sleep(for: .milliseconds(50))
        open.cancel()
        #expect(await open.value == .none)
        #expect(ContinuousClock.now - started < .seconds(5))
        for _ in 0..<100 where !host.openSawCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(host.openSawCancelled)
    }

    @Test func aHostCannotListAConversationAsAnotherHostsOrAsAProcess() async {
        let host = FakeHost()
        var foreign = Self.thread("t9")
        foreign.host?.host = "other"
        host.conversations = [Self.thread("t1"), foreign, AgentSession(agent: "example", id: "bare", pid: 5, cwd: "/src", state: .idle)]
        let hub = makeHub(host)
        await hub.rescan()
        #expect(hub.directory.conversations.map(\.id) == [Self.id("t1")])
        #expect(hub.directory.conversations.first?.pid == nil)
    }

    @Test func aThreadIdThatLooksLikeAnInstanceSuffixStillGetsItsOwnConversation() {
        let plain = AgentHostLocation(host: "example", instance: "b@c", native: "a")
        let tricky = AgentHostLocation(host: "example", instance: "c", native: "a@b")
        #expect(plain.conversationKey != tricky.conversationKey)
    }
}
