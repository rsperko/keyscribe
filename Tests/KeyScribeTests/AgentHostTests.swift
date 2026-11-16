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
        var shownInstead: [String: String] = [:]
        var answers = true
        var hangs = false
        var opening = AgentHostOpen.opened
        var front = AgentHostFront.unknown
        var identityKeys = ["EXAMPLE_THREAD"]
        var delivery = AgentHostDelivery.accepted
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

        private func stall() async {
            guard hangs else { return }
            try? await Task.sleep(for: .seconds(30))
        }

        func scan() async -> AgentHostScan {
            scans += 1
            return answers ? .found(conversations, titles: titles, shownInstead: shownInstead) : .unreadable("not running")
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

        func front(among locations: [AgentHostLocation], reported: AgentHostLocation?) async -> AgentHostFront {
            asked.append(locations)
            self.reported.append(reported)
            await stall()
            return front
        }

        func rename(_ location: AgentHostLocation, to name: String) async -> Bool {
            retitled.append((location, name))
            return true
        }

        var whileDelivering: (@MainActor () -> Void)?

        func deliver(_ text: String, images: [String], request: String, to location: AgentHostLocation) async -> AgentHostDelivery {
            delivered.append((text, request, location))
            deliveredImages.append(images)
            whileDelivering?()
            await stall()
            return delivery
        }
    }

    static let instance = "http://127.0.0.1:9"

    static func location(_ native: String, instance: String = instance) -> AgentHostLocation {
        AgentHostLocation(host: "example", instance: instance, native: native)
    }

    static func id(_ native: String, instance: String = instance) -> String {
        AgentSessionID.make(agent: "example", native: location(native, instance: instance).conversationKey)
    }

    static func thread(_ native: String, cwd: String = "/src/docs", instance: String = instance, startedAt: Int? = nil) -> AgentSession {
        AgentSession(
            agent: "example", id: native, pid: 77, cwd: cwd, state: .idle, startedAt: startedAt, host: location(native, instance: instance))
    }

    private func makeHub(
        _ host: FakeHost, transport: FakeTransport = FakeTransport(), focus: FakeFocus? = nil, front: FakeFront? = nil,
        names: AgentNameStore? = nil, places: (any AgentPlaceReading)? = nil, allowed: @escaping @MainActor (String) -> Bool = { _ in true }, hostDeadline: Duration = .milliseconds(50),
        claude: FakeDiscovery = FakeDiscovery(kind: .claude), environments: [Int: [String: String]] = [:], handOffLimit: Duration = .seconds(30),
        parents: [Int: Int] = [:], now: @escaping () -> Date = Date.init
    ) -> AgentHub {
        AgentHub(
            transport: transport, discovery: [claude], names: names, focus: focus, front: front,
            receiptTimeout: .milliseconds(50), handOffLimit: handOffLimit, scanDeadline: .seconds(30), places: places,
            hosts: [AgentHostIntegration(kind: Self.kind, make: { host })], hostAllowed: allowed, hostDeadline: hostDeadline,
            processEnvironment: { pid, keys in (environments[pid] ?? [:]).filter { keys.contains($0.key) } },
            processParent: { parents[$0] }, now: now,
            makeId: { "r1" })
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
        #expect(focus.focused.isEmpty)
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
        (.refused("thread is archived"), .notSent("docs", reason: .refused("thread is archived"))),
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
        hub.onResult = { conversation, handle, reply, requested, origin in results.append([conversation, handle, reply, "\(requested)", origin]) }
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
        hub.onResult = { _, _, reply, _, origin in results.append([reply, origin]) }
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
        hub.onResult = { _, _, _, _, origin in origins.append(origin) }
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
        hub.onResult = { _, _, reply, _, origin in
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
        hub.onResult = { _, _, reply, _, _ in replies.append(reply) }
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
        hub.onResult = { _, _, reply, _, _ in replies.append(reply) }
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
        hub.onResult = { _, _, reply, _, _ in replies.append(reply) }
        host.whileDelivering = { hub.handle(.turnStarted(session: Self.id("t1"), turn: "a", prompt: AgentPromptDigest.of("say kiwi"))) }
        _ = await hub.deliver("say kiwi", to: Self.id("t1"), request: "q1")
        hub.handle(.turnComplete(session: Self.id("t1"), reason: "complete", answer: "kiwi"))
        #expect(replies == ["kiwi"])
    }

    @Test func aDictationIsNotFollowedThroughAnAgentWhoseConnectorCannotNameItsTurnsPrompt() async {
        let host = FakeHost()
        let hub = await joined(host, features: [])
        var replies: [String] = []
        hub.onResult = { _, _, reply, _, _ in replies.append(reply) }
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
        hub.onResult = { conversation, _, answer, requested, _ in results.append((conversation, answer, requested)) }
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
        hub.onResult = { _, _, answer, _, _ in results.append(answer) }
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
        hub.onResult = { _, _, answer, _, _ in results.append(answer) }
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
        hub.onResult = { _, _, answer, _, _ in results.append(answer) }
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
        hub.onResult = { _, _, answer, _, _ in results.append(answer) }
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
        hub.onResult = { conversation, _, _, _, _ in results.append(conversation) }
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
        var hello = Self.hostHello("t1")
        hello.version = "0.1.0-plugin"
        #expect(hub.filing(for: hello) == nil)
        hub.handle(.hello(hello))
        #expect(hub.loadedVersions[Self.id("t1")] == nil)
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
        hub.onResult = { _, _, reply, _, _ in replies.append(reply) }
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
        hub.onResult = { _, _, reply, _, _ in replies.append(reply) }
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
        hub.onResult = { _, _, reply, _, _ in replies.append(reply) }
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
        hub.onResult = { _, _, reply, _, _ in replies.append(reply) }
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
        let started = ContinuousClock.now
        #expect(await hub.deliver("fix the test", to: Self.id("t1")) == .uncertain("docs"))
        #expect(await hub.open(Self.id("t1")) == .none)
        #expect(await hub.sessionInFront() == nil)
        #expect(ContinuousClock.now - started < .seconds(10))
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
