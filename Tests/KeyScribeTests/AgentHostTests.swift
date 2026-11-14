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
        var conversations: [AgentSession] = []
        var answers = true
        var hangs = false
        var opening = AgentHostOpen.opened
        var front = AgentHostFront.unknown
        var delivery = AgentHostDelivery.accepted
        private(set) var scans = 0
        private(set) var opened: [AgentHostLocation] = []
        private(set) var asked: [[AgentHostLocation]] = []
        private(set) var delivered: [(String, String, AgentHostLocation)] = []

        var calls: Int { scans + opened.count + asked.count + delivered.count }

        private func stall() async {
            guard hangs else { return }
            try? await Task.sleep(for: .seconds(30))
        }

        func scan() async -> AgentHostScan {
            scans += 1
            return answers ? .found(conversations) : .unreadable("not running")
        }

        func open(_ location: AgentHostLocation) async -> AgentHostOpen {
            opened.append(location)
            await stall()
            return opening
        }

        func front(among locations: [AgentHostLocation]) async -> AgentHostFront {
            asked.append(locations)
            await stall()
            return front
        }

        func deliver(_ text: String, request: String, to location: AgentHostLocation) async -> AgentHostDelivery {
            delivered.append((text, request, location))
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
        names: AgentNameStore? = nil, now: @escaping () -> Date = Date.init
    ) -> AgentHub {
        AgentHub(
            transport: transport, discovery: [FakeDiscovery(kind: .claude)], names: names, focus: focus, front: front,
            receiptTimeout: .milliseconds(50), scanDeadline: .seconds(30),
            hosts: [AgentHostIntegration(kind: Self.kind, make: { host })], hostDeadline: .milliseconds(50), now: now, makeId: { "r1" })
    }

    @Test func aHostTheUserHasNotTurnedOnIsNeverCalled() async {
        let host = FakeHost()
        host.isEnabled = false
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        #expect(hub.directory.conversations.isEmpty)
        #expect(await hub.sessionInFront() == nil)
        #expect(await hub.open(Self.id("t1")) == .none)
        #expect(host.calls == 0)
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
        host.front = .unknown
        #expect(await hub.sessionInFront() == nil)
        let terminal = FrontSession(id: "claude:s1", app: FrontApp(bundle: "com.mitchellh.ghostty", pid: 9, name: "Ghostty"))
        front.answer = terminal
        let asked = host.asked.count
        #expect(await hub.sessionInFront() == terminal)
        #expect(host.asked.count == asked)
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

    @Test func aClipboardImageReachesAHostedConversationAsTheFilePathInTheText() async {
        let host = FakeHost()
        host.conversations = [Self.thread("t1")]
        let hub = makeHub(host)
        await hub.rescan()
        let text = "look at /tmp/clip.png"
        #expect(await hub.deliver(text, to: Self.id("t1"), images: ["/tmp/clip.png"]) == .sent("docs"))
        #expect(host.delivered.map(\.0) == [text])
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
        let second = makeHub(restarted, names: AgentNameStore(directory: dir))
        second.refresh()
        await second.rescan()
        restarted.answers = true
        await second.rescan(rereadingTitles: true)
        #expect(second.names == ["docs blue": Self.id("t2")])
    }

    @Test func hostedNamesSurviveTurningTheHostOffAndOnEvenWhenTheListIsRefreshedBeforeItAnswers() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-host-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = FakeHost()
        host.conversations = [Self.thread("t1", startedAt: 100), Self.thread("t2", startedAt: 200)]
        let hub = makeHub(host, names: AgentNameStore(directory: dir))
        await hub.rescan()
        #expect(hub.names == ["docs": Self.id("t1"), "docs blue": Self.id("t2")])
        host.isEnabled = false
        await hub.rescan(rereadingTitles: true)
        #expect(hub.names.isEmpty)
        host.isEnabled = true
        hub.refresh()

        let restarted = FakeHost()
        restarted.conversations = [Self.thread("t2", startedAt: 200)]
        let second = makeHub(restarted, names: AgentNameStore(directory: dir))
        await second.rescan()
        #expect(second.names == ["docs blue": Self.id("t2")])
    }

    @Test func theHostIsAskedForItsConversationsNoMoreOftenThanTheFallbackIntervalUnlessTheUserAsks() async {
        let host = FakeHost()
        var clock = Date(timeIntervalSince1970: 1000)
        let hub = makeHub(host, now: { clock })
        await hub.rescan(rereadingTitles: false)
        await hub.rescan(rereadingTitles: false)
        #expect(host.scans == 1)
        clock = clock.addingTimeInterval(HostDiscovery.fallbackInterval)
        await hub.rescan(rereadingTitles: false)
        #expect(host.scans == 2)
        await hub.rescan(rereadingTitles: true)
        #expect(host.scans == 3)
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
