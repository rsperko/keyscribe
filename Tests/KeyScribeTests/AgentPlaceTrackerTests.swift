import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct AgentPlaceTrackerTests {
    final class Reader: AgentPlaceReading, @unchecked Sendable {
        private let lock = NSLock()
        private var _answers: [String: AgentPlaceAnswer] = [:]
        private var _reads = 0
        var answers: [String: AgentPlaceAnswer] {
            get { lock.withLock { _answers } }
            set { lock.withLock { _answers = newValue } }
        }
        var reads: Int { lock.withLock { _reads } }
        func read(_ queries: [AgentPlaceQuery]) -> [String: AgentPlaceAnswer] {
            lock.withLock {
                _reads += 1
                return Dictionary(uniqueKeysWithValues: queries.map { ($0.id, _answers[$0.id] ?? .absent) })
            }
        }
    }

    final class Registry: @unchecked Sendable {
        var entries: [ClaudeRegistryEntry] = []
    }

    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1000) }

    private func place(pane: String?, paneId: String = "p1") -> AgentPlace {
        let key = "/s#pane:\(paneId)"
        var labels = [AgentPlace.Label]()
        if let pane { labels.append(.init(text: pane, level: .pane, container: key)) }
        labels.append(.init(text: "cos", level: .workspace, container: "/s#workspace:w1"))
        return AgentPlace(surface: "herdr", labels: labels, containers: [key, "/s#tab:t1", "/s#workspace:w1"])
    }

    private func makeHub(_ reader: Reader, clock: Clock = Clock(), names: AgentNameStore? = nil)
        -> (AgentHub, Registry) {
        let registry = Registry()
        registry.entries = [ClaudeRegistryEntry(pid: 10, sessionId: "a", cwd: "/src/home", name: nil, status: "idle", waitingFor: nil, startedAt: 100)]
        let hub = AgentHub(
            transport: AgentHubTests.FakeTransport(), scan: { registry.entries }, names: names, scanDeadline: .seconds(30),
            places: reader, now: { clock.now }, stillRunning: { _ in false })
        return (hub, registry)
    }

    private func settle(_ hub: AgentHub) async {
        for _ in 0..<50 {
            if let reading = hub.placeTracker?.reading { await reading.value } else { await Task.yield() }
        }
    }

    @Test func aPaneLabelReadInTheBackgroundNamesTheConversation() async {
        let reader = Reader()
        reader.answers = ["claude:a": .found(place(pane: "architect"))]
        let (hub, _) = makeHub(reader)
        await hub.rescan()
        await settle(hub)
        #expect(hub.names == ["architect": "claude:a"])
    }

    @Test func aFailedReadKeepsTheLastNameAndAConfirmedRemovalFallsBack() async {
        let reader = Reader()
        reader.answers = ["claude:a": .found(place(pane: "architect"))]
        let (hub, _) = makeHub(reader)
        await hub.rescan()
        await settle(hub)
        reader.answers = ["claude:a": .unknown]
        hub.readPlaces()
        await settle(hub)
        #expect(hub.names == ["architect": "claude:a"])
        reader.answers = ["claude:a": .absent]
        hub.readPlaces()
        await settle(hub)
        #expect(hub.names == ["home": "claude:a"])
    }

    @Test func labelsAreReadOftenOnlyWhileAConversationSitsInAPlace() async {
        let reader = Reader()
        let clock = Clock()
        let (hub, _) = makeHub(reader, clock: clock)
        await hub.rescan()
        await settle(hub)
        let first = reader.reads
        clock.now += AgentPlaceTracker.busyInterval
        hub.tickPlaces(settingsOpen: true)
        await settle(hub)
        #expect(reader.reads == first)
        clock.now += AgentPlaceTracker.quietInterval
        hub.tickPlaces(settingsOpen: true)
        await settle(hub)
        #expect(reader.reads == first + 1)
        reader.answers = ["claude:a": .found(place(pane: "architect"))]
        clock.now += AgentPlaceTracker.quietInterval
        hub.tickPlaces(settingsOpen: true)
        await settle(hub)
        clock.now += AgentPlaceTracker.busyInterval
        hub.tickPlaces(settingsOpen: true)
        await settle(hub)
        #expect(reader.reads == first + 3)
    }

    @Test func placesAreNotReadOnATimerWhileSettingsIsClosed() async {
        let reader = Reader()
        let clock = Clock()
        let (hub, _) = makeHub(reader, clock: clock)
        reader.answers = ["claude:a": .found(place(pane: "architect"))]
        await hub.rescan()
        await settle(hub)
        let first = reader.reads
        clock.now += AgentPlaceTracker.quietInterval
        hub.tickPlaces(settingsOpen: false)
        await settle(hub)
        #expect(reader.reads == first)
        hub.readPlaces()
        await settle(hub)
        #expect(reader.reads == first + 1)
    }

    @Test func aPlaceWithoutAnyNameIsReadOnlyAsOftenAsNoPlace() async {
        let reader = Reader()
        let clock = Clock()
        let (hub, _) = makeHub(reader, clock: clock)
        reader.answers = ["claude:a": .found(AgentPlace(surface: "Ghostty", labels: [], containers: ["ghostty#terminal:t1"]))]
        await hub.rescan()
        await settle(hub)
        let first = reader.reads
        clock.now += AgentPlaceTracker.busyInterval
        hub.tickPlaces(settingsOpen: true)
        await settle(hub)
        #expect(reader.reads == first)
    }

    @Test func aReplacementConversationInThePaneGetsItsNameButNothingElse() async {
        let reader = Reader()
        reader.answers = ["claude:a": .found(place(pane: "architect")), "claude:b": .found(place(pane: "architect"))]
        let (hub, registry) = makeHub(reader)
        await hub.rescan()
        await settle(hub)
        hub.makeCurrent("claude:a")
        registry.entries = [ClaudeRegistryEntry(pid: 20, sessionId: "b", cwd: "/src/home", name: nil, status: "idle", waitingFor: nil, startedAt: 200)]
        await hub.rescan()
        await settle(hub)
        #expect(hub.names == ["architect": "claude:b"])
        #expect(hub.current == nil)
    }

    @Test func useDefaultNameDropsTheOverrideSavesItAndKeepsTheNameWhenSavingFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-place-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let reader = Reader()
        reader.answers = ["claude:a": .found(place(pane: "architect"))]
        let (hub, _) = makeHub(reader, names: AgentNameStore(directory: dir))
        await hub.rescan()
        await settle(hub)
        try hub.rename("claude:a", to: "builder")
        #expect(hub.defaultName(for: "claude:a")?.name == "architect")

        let file = dir.appendingPathComponent(AgentNameStore.fileName)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dir.path)
        #expect(throws: (any Error).self) { try hub.useDefaultName("claude:a") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(hub.names == ["builder": "claude:a"])

        try hub.useDefaultName("claude:a")
        #expect(hub.names == ["architect": "claude:a"])
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("builder"))
    }
}

@MainActor
struct AgentPlaceRestartTests {
    @Test func aRememberedPlaceNameSurvivesARestartWhoseFirstReadFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-place-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func entry(_ id: String, pid: Int) -> ClaudeRegistryEntry {
            ClaudeRegistryEntry(pid: pid, sessionId: id, cwd: "/src/home", name: nil, status: "idle", waitingFor: nil, startedAt: pid * 100)
        }
        func place(_ pane: String) -> AgentPlace {
            AgentPlace(surface: "herdr", labels: [.init(text: "cos", level: .workspace, container: "/s#workspace:w1")],
                       containers: ["/s#pane:\(pane)", "/s#tab:t1", "/s#workspace:w1"])
        }
        func settle(_ hub: AgentHub) async {
            for _ in 0..<50 {
                if let reading = hub.placeTracker?.reading { await reading.value } else { await Task.yield() }
            }
        }
        let firstReader = AgentPlaceTrackerTests.Reader()
        firstReader.answers = ["claude:a": .found(place("p1")), "claude:b": .found(place("p2"))]
        var entries = [entry("a", pid: 10), entry("b", pid: 20)]
        let first = AgentHub(
            transport: AgentHubTests.FakeTransport(), scan: { [entries] in entries }, names: AgentNameStore(directory: dir),
            scanDeadline: .seconds(30), places: firstReader, stillRunning: { _ in true })
        await first.rescan()
        await settle(first)
        #expect(first.names["cos claude"] == "claude:a")
        first.stop()

        entries = [entry("a", pid: 10)]
        let reader = AgentPlaceTrackerTests.Reader()
        reader.answers = ["claude:a": .unknown]
        let second = AgentHub(
            transport: AgentHubTests.FakeTransport(), scan: { [entries] in entries }, names: AgentNameStore(directory: dir),
            scanDeadline: .seconds(30), places: reader, stillRunning: { _ in true })
        await second.rescan()
        await settle(second)
        #expect(second.names == ["cos claude": "claude:a"])
        #expect(!second.placesUnread(["claude:a"]))
        #expect(second.placeTracker?.failingSince["claude:a"] != nil)
        reader.answers = ["claude:a": .found(place("p1"))]
        second.readPlaces()
        await settle(second)
        #expect(second.names == ["cos claude": "claude:a"])
        #expect(!second.placesUnread(["claude:a"]))
        #expect(second.placeTracker?.failingSince["claude:a"] == nil)
    }
}

@MainActor
struct AgentGeneratedTitleTests {
    @Test func aConnectorTitleEqualToTheAgentsGeneratedTitleNeverNamesTheConversation() async {
        let entries = [ClaudeRegistryEntry(
            pid: 10, sessionId: "a", cwd: "/src/home", name: "Chief of staff tracking", status: "idle", waitingFor: nil, nameSource: "auto")]
        let hub = AgentHub(transport: AgentHubTests.FakeTransport(), scan: { entries }, scanDeadline: .seconds(30), stillRunning: { _ in false })
        await hub.rescan()
        hub.handle(.title(session: "claude:a", text: "Chief of staff tracking"))
        #expect(hub.names == ["home": "claude:a"])
        hub.handle(.title(session: "claude:a", text: "tracker"))
        #expect(hub.names == ["tracker": "claude:a"])
    }
}
