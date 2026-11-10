import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct AgentDeliveryWiringTests {
    private final class FixedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Fixed"
        let supportsRecognitionBias = false
        private let text: String
        init(text: String) { self.text = text }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { text }
        func evict() async {}
    }

    private final class FakeAudio: AudioCapturing, @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var lost: (@Sendable () -> Void)?
        init(url: URL) { self.url = url }
        func start(sampleRate: Int) async throws -> URL { url }
        func stop() -> URL? { url }
        func setCaptureLostHandler(_ handler: @escaping @Sendable () -> Void) { lock.withLock { lost = handler } }
        func loseCapture() { lock.withLock { lost }?() }
    }

    private final class Transport: AgentTransport {
        var sent: [(AgentCommand, String)] = []
        var confirms = true
        var uncertainThenConfirmed = false
        var live = true
        var unreachable: Set<String> = []
        weak var hub: AgentHub?
        func enqueue(_ command: AgentCommand, for session: String) {
            sent.append((command, session))
            if uncertainThenConfirmed {
                Task { @MainActor [weak hub] in
                    hub?.handle(.undelivered(request: command.id, reason: "", handedOff: true))
                    hub?.handle(.submitted(request: command.id, turn: ""))
                }
                return
            }
            guard confirms else { return }
            Task { @MainActor [weak hub] in hub?.handle(.submitted(request: command.id, turn: "")) }
        }
        func isLive(session: String) -> Bool { live && !unreachable.contains(session) }
        func forget(session: String) {}
        func withdraw(_ id: String) -> Bool { false }
    }

    private final class HUDSpy: HUDPresenting {
        var states: [HUDState] = []
        func render(_ state: HUDState) { states.append(state) }
    }

    private final class HangingLLM: LLMClient, @unchecked Sendable {
        let started = Signal()
        let release = Signal()
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            started.fire()
            await release.wait()
            return "rewritten"
        }
    }

    private final class SlowReasoningLLM: LLMClient, @unchecked Sendable {
        let asked = Signal()
        let release = Signal()
        func complete(system: String, user: String, connection: Connection) async throws -> String { "rewritten" }
        func reasoningOutcome(for connection: Connection) async -> ReasoningOutcome? {
            asked.fire()
            await release.wait()
            return nil
        }
    }

    private final class FailingLLM: LLMClient, @unchecked Sendable {
        struct Failure: Error {}
        func complete(system: String, user: String, connection: Connection) async throws -> String { throw Failure() }
    }

    private final class ChoiceRunner: VoiceCommandRunning {
        var onProgress: (@MainActor (VoiceCommandProgress) -> Void)?
        var pendingChoice: VoiceCommandPendingChoice?
        func run(
            transcript: String, places: [VoiceCommandPlace], scripts: [VoiceCommandScript], origin: VoiceCommandOrigin?,
            stillWanted: @escaping @MainActor () -> Bool, onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void
        ) async -> VoiceCommandOutcome {
            .done(summary: "", command: "")
        }
    }

    private final class BackRunner: VoiceCommandRunning {
        var onProgress: (@MainActor (VoiceCommandProgress) -> Void)?
        var outcome: VoiceCommandOutcome = .done(summary: "TextEdit", command: "Returns to TextEdit.")
        var whileRunning: @MainActor () -> Void = {}
        private(set) var recorded: [VoiceCommandOrigin] = []
        private(set) var ran: [(transcript: String, origin: VoiceCommandOrigin?)] = []
        func run(
            transcript: String, places: [VoiceCommandPlace], scripts: [VoiceCommandScript], origin: VoiceCommandOrigin?,
            stillWanted: @escaping @MainActor () -> Bool, onLateResult: @escaping @MainActor (VoiceCommandOutcome) -> Void
        ) async -> VoiceCommandOutcome {
            ran.append((transcript, origin))
            whileRunning()
            return stillWanted() ? outcome : .abandoned
        }
        func recordReturn(to origin: VoiceCommandOrigin) { recorded.append(origin) }
        private(set) var sessions: SessionReturns?
        func returnToSessions(_ sessions: SessionReturns?) { self.sessions = sessions }
    }

    private final class Front: AgentFronting, @unchecked Sendable {
        var answer: FrontSession?
        init(_ id: String? = nil, window: String? = "cg:3") {
            answer = id.map { FrontSession(id: $0, app: FrontApp(bundle: "com.mitchellh.ghostty", pid: 9, name: "Ghostty", window: window)) }
        }
        func shown(among agents: [AgentFrontCandidate], asking: @escaping @MainActor @Sendable (String) -> Void) async -> FrontSession? { answer }
    }

    private final class SlowFront: AgentFronting, @unchecked Sendable {
        let release = Signal("slow front released")
        private var calls = 0
        func shown(among agents: [AgentFrontCandidate], asking: @escaping @MainActor @Sendable (String) -> Void) async -> FrontSession? {
            calls += 1
            guard calls == 1 else { return nil }
            await release.wait()
            return FrontSession(id: "claude:s2", app: FrontApp(bundle: "com.mitchellh.ghostty", pid: 9, name: "Ghostty", window: "cg:3"))
        }
    }

    private final class BlockedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Blocked"
        let supportsRecognitionBias = false
        let release = Signal("transcription released")
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String {
            await release.wait()
            return "Run the tests."
        }
        func evict() async {}
    }

    private final class Captured: @unchecked Sendable {
        var insertedText: String?
    }

    private final class FrontWindow: @unchecked Sendable {
        var snapshot: TargetSnapshot
        init(_ snapshot: TargetSnapshot) { self.snapshot = snapshot }
    }

    private final class Registry: @unchecked Sendable {
        var firstStatus = "idle"
        var firstWaitingFor: String?
        var unreadable = false
        var firstPid = 10
    }

    private struct Rig {
        let controller: DictationController
        let hub: AgentHub
        let transport: Transport
        let hud: HUDSpy
        let captured: Captured
        let history: HistoryStore
        let supportDir: URL
        let registry: Registry
        let audio: FakeAudio

        var sent: [(AgentCommand, String)] { transport.sent }
        var texts: [String] {
            sent.compactMap { if case .submit(_, _, let text, _, _) = $0.0 { text } else { nil } }
        }
    }

    private func agentMode(target: Mode.Agent.Target = .current) -> Mode {
        var mode = Mode.codingAgent
        mode.agent = .init(target: target)
        return mode
    }

    private func rig(
        _ transcript: String, modes: [Mode]? = nil, current: String? = nil, enabled: Bool = true,
        connection: Connection? = nil, llm: (any LLMClient)? = nil, voiceCommands: VoiceCommandRunning? = nil,
        namesFile: String? = nil, focus: AgentTerminalFocusing? = nil, firstStatus: String = "idle", firstWaitingFor: String? = nil,
        firstPid: Int = 10,
        historyEnabled: Bool = true, receiptTimeout: Duration = .seconds(8),
        front: FrontWindow = FrontWindow(TargetSnapshot(bundleId: "test.bundle")), sessionInFront: Front = Front(),
        glance: (any AgentFronting)? = nil, engine: (any SpeechEngine)? = nil, frontGrace: Duration = .seconds(1),
        maxRecordingSeconds: Double = RecordingLimit.backstopSeconds, places: (any AgentPlaceReading)? = nil
    ) async -> Rig {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-agent-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        for mode in modes ?? [agentMode()] { try? ModeStore.write(mode, to: modesDir) }
        if let connection { try? ConnectionStore.write(ConnectionSet(connections: [connection]), to: supportDir) }

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        settings.features.setEnabled(enabled, for: .codingAgents)
        settings.history = .init(enabled: historyEnabled, retentionDays: 7)

        let transport = Transport()
        let registry = Registry()
        registry.firstStatus = firstStatus
        registry.firstWaitingFor = firstWaitingFor
        registry.firstPid = firstPid
        let entries: @Sendable () -> [ClaudeRegistryEntry]? = {
            registry.unreadable ? nil : [
                ClaudeRegistryEntry(pid: registry.firstPid, sessionId: "s1", cwd: "/src/keyscribe", name: nil, status: registry.firstStatus, waitingFor: registry.firstWaitingFor),
                ClaudeRegistryEntry(pid: 11, sessionId: "s2", cwd: "/src/keyscribe", name: nil, status: "idle", waitingFor: nil),
            ]
        }
        let agentsDir = supportDir.appendingPathComponent("agents", isDirectory: true)
        if let namesFile {
            try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            try? Data(namesFile.utf8).write(to: agentsDir.appendingPathComponent(AgentNameStore.fileName))
        }
        let hub = AgentHub(transport: transport, scan: { entries() }, names: AgentNameStore(directory: agentsDir), focus: focus,
                           front: sessionInFront, glance: glance, receiptTimeout: receiptTimeout, scanDeadline: .seconds(30),
                           places: places)
        transport.hub = hub
        await hub.rescan()
        if let current { hub.makeCurrent(current) }

        let captured = Captured()
        let hud = HUDSpy()
        let history = HistoryStore(supportDir: supportDir)
        let provider = try! SpeechEngineProvider(engines: [engine ?? FixedEngine(text: transcript)], activeId: "fixed")
        let config = ConfigCache(supportDir: supportDir)
        config.codingAgentsEnabled = true
        let audio = FakeAudio(url: supportDir.appendingPathComponent("capture.wav"))
        let controller = DictationController(
            settings: settings, provider: provider, config: config,
            history: history, hud: hud, permits: { _ in true },
            audio: audio,
            insert: { _, _, _, text, _ in captured.insertedText = text; return true },
            submitKey: { _ in },
            snapshot: { front.snapshot },
            micStatus: { .granted },
            accessibilityGranted: { true },
            llmClient: llm ?? HTTPLLMClient(),
            voiceCommands: voiceCommands,
            maxRecordingSeconds: maxRecordingSeconds)
        controller.agents = hub
        controller.frontReadingGrace = frontGrace
        hub.onNotice = { [weak controller] in controller?.showAgentNotice($0, request: $1) }
        hub.onForget = { [weak controller] in controller?.forgetAgentReceipt(request: $0) }
        controller.agentNoticeDelayOverride = .milliseconds(10)
        return Rig(
            controller: controller, hub: hub, transport: transport, hud: hud, captured: captured, history: history,
            supportDir: supportDir, registry: registry, audio: audio)
    }

    private func take(_ rig: Rig, mode: String = Mode.codingAgentId, readingTheFront: Bool = false) async {
        rig.controller.setNextModeOverride(id: mode)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        if readingTheFront { await rig.controller.agentFrontTask?.value }
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
    }

    private func rosters(_ rig: Rig) -> [AgentRoster?] {
        rig.hud.states.compactMap { if case .recording(_, _, _, _, let agents) = $0 { agents } else { nil } }
    }

    @Test func aPaneRenamedJustBeforeRecordingIsReachedByItsNewNameOnceTheReadLandsDuringTheTake() async {
        let reader = AgentPlaceTrackerTests.Reader()
        let rig = await rig("architect, run the tests.", current: "claude:s2", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        let pane = "/s#pane:p1"
        reader.answers = ["claude:s1": .found(AgentPlace(
            surface: "herdr", labels: [.init(text: "architect", level: .pane, container: pane)], containers: [pane]))]
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["run the tests."])
        #expect(rosters(rig).compactMap { $0?.rows.map(\.name) }.allSatisfy { $0 == ["keyscribe blue", "keyscribe"] })
    }

    private func herdrNamedRig(_ text: String, firstStatus: String = "idle", firstWaitingFor: String? = nil) async -> Rig {
        let reader = AgentPlaceTrackerTests.Reader()
        let rig = await rig(text, current: "claude:s2", firstStatus: firstStatus, firstWaitingFor: firstWaitingFor, places: reader)
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        let pane = "/s#pane:p1", workspace = "/s#workspace:w9"
        reader.answers = ["claude:s1": .found(AgentPlace(
            surface: "herdr",
            labels: [
                .init(text: "marvin", level: .title, container: pane), .init(text: "cos", level: .agent, container: pane),
                .init(text: "chief", level: .workspace, container: workspace),
            ],
            containers: [pane, workspace]))]
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        return rig
    }

    @Test(arguments: [
        ("Ask cos what's outstanding and what we're waiting on.", "what's outstanding and what we're waiting on."),
        ("Ask Marvin what we should do next.", "what we should do next."),
    ])
    func theNameHerdrShowsAndTheAgentNameBothReachTheConversation(text: String, body: String) async {
        let rig = await herdrNamedRig(text)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == [body])
    }

    @Test func aWorkspaceLabelThatLostTheNameIsHeldAndNamesTheConversation() async {
        let rig = await herdrNamedRig("Ask chief what we should do next.")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error(let message, _, _) = $0 {
                message == "Not sent: \u{201C}chief\u{201D} is the herdr workspace label of \u{201C}marvin\u{201D}. Try \u{201C}ask marvin, \u{2026}\u{201D}"
            } else { false }
        })
        #expect(await lastHistoryEntry(rig)?.failureReason == "Not sent: \u{201C}chief\u{201D} is the herdr workspace label of \u{201C}marvin\u{201D}")
    }

    @Test(arguments: ["What is cos waiting for?", "What is marvin waiting for?"])
    func aStatusQuestionReachesTheConversationByEitherName(text: String) async {
        let rig = await herdrNamedRig(text, firstStatus: "waiting", firstWaitingFor: "permission prompt")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        #expect(rig.sent.isEmpty)
        #expect(showsAnswer(rig, "marvin is waiting for approval. Say \u{201C}open marvin\u{201D} to see it."))
    }

    @Test func aRetryUsesTheNameAPaneTookDuringTheTakeNotTheOneItLeft() async {
        let reader = AgentPlaceTrackerTests.Reader()
        let rig = await rig("Tell frontend to run the tests.", current: "claude:s1", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        let pane = "/s#pane:p1"
        reader.answers = ["claude:s1": .found(AgentPlace(
            surface: "herdr", labels: [.init(text: "zeta", level: .pane, container: pane)], containers: [pane]))]
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error(let message, _, _) = $0 {
                message == "Not sent: no conversation named \u{201C}frontend\u{201D}. Try \u{201C}tell zeta, \u{2026}\u{201D}"
            } else { false }
        })
    }

    final class SlowReader: AgentPlaceReading, @unchecked Sendable {
        private let lock = NSLock()
        private var _answers: [String: AgentPlaceAnswer] = [:]
        private var _delay: TimeInterval = 0
        let release = DispatchSemaphore(value: 0)
        private var _blocking = false
        var answers: [String: AgentPlaceAnswer] {
            get { lock.withLock { _answers } }
            set { lock.withLock { _answers = newValue } }
        }
        var delay: TimeInterval {
            get { lock.withLock { _delay } }
            set { lock.withLock { _delay = newValue } }
        }
        var blocking: Bool {
            get { lock.withLock { _blocking } }
            set { lock.withLock { _blocking = newValue } }
        }
        func read(_ queries: [AgentPlaceQuery]) -> [String: AgentPlaceAnswer] {
            if blocking { _ = release.wait(timeout: .now() + 5) }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let known = answers
            return Dictionary(uniqueKeysWithValues: queries.map { ($0.id, known[$0.id] ?? .absent) })
        }
    }

    private func architect() -> [String: AgentPlaceAnswer] {
        let pane = "/s#pane:p1"
        return ["claude:s1": .found(AgentPlace(
            surface: "herdr", labels: [.init(text: "architect", level: .pane, container: pane)], containers: [pane]))]
    }

    @Test func aTakeWaitingOnALabelReadThatDoesNotFinishIsHeldInsteadOfGoingToTheCurrentConversation() async {
        let reader = SlowReader()
        let rig = await rig("architect, run the tests.", current: "claude:s2", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        rig.controller.placeNamesGrace = .milliseconds(50)
        reader.answers = architect()
        reader.blocking = true
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
        reader.blocking = false
        reader.release.signal()
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
    }

    @Test func aTakeWhileAConversationsFirstReadIsStillRunningPastTheGraceIsHeld() async {
        let reader = SlowReader()
        reader.answers = architect()
        reader.blocking = true
        let rig = await rig("architect, run the tests.", current: "claude:s2", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.placeNamesGrace = .milliseconds(50)
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
        reader.blocking = false
        reader.release.signal()
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
    }

    @Test func aFirstReadThatFailsIsShownAndTheTakeGoesToTheCurrentConversation() async {
        let reader = SlowReader()
        reader.answers = ["claude:s1": .unknown]
        let rig = await rig("Run the tests.", current: "claude:s2", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        #expect(rig.hub.placeTracker?.failingSince["claude:s1"] != nil)
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
    }

    @Test func aTakeAfterAFailedReadOfAPlaceReadBeforeKeepsItsNamesAndGoesToTheCurrentConversation() async {
        let reader = SlowReader()
        reader.answers = architect()
        let rig = await rig("Run the tests.", current: "claude:s2", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        reader.answers = ["claude:s1": .unknown]
        rig.hub.readPlaces()
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        #expect(rig.hub.names["architect"] == "claude:s1")
        #expect(rig.hub.placeTracker?.failingSince["claude:s1"] != nil)
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
    }

    @Test func aTakeNamingAKnownConversationIsSentEvenWhileAnotherConversationsLabelIsUnchecked() async {
        let reader = SlowReader()
        let rig = await rig("Tell keyscribe blue to run the tests.", current: "claude:s1", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        reader.answers = ["claude:s1": .unknown]
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
    }

    @Test func aTakeWaitsBrieflyForALabelReadStillRunningAndReachesTheRenamedPane() async {
        let reader = SlowReader()
        let rig = await rig("architect, run the tests.", current: "claude:s2", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        rig.controller.placeNamesGrace = .seconds(3)
        reader.answers = architect()
        reader.delay = 0.3
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["run the tests."])
    }

    @Test func whileRecordingTheHUDListsTheRecipientFirstThenTheOtherSessions() async {
        let rig = await rig("Run the tests.", current: "claude:s2")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let roster = try? #require(rosters(rig).last ?? nil)
        #expect(roster?.rows.map(\.name) == ["keyscribe blue", "keyscribe"])
        #expect(roster?.recipientName == "keyscribe blue")
        #expect(roster?.source == .current)
    }

    @Test func anOrdinaryDictationShowsNoSessionList() async {
        let rig = await rig("hello", modes: [agentMode(), .direct], current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, mode: Mode.directId)
        #expect(!rosters(rig).isEmpty)
        #expect(rosters(rig).allSatisfy { $0 == nil })
    }

    @Test func aSpokenNameSendsTheRestToThatConversationAndMakesItCurrent() async {
        let rig = await rig("Tell keyscribe blue to run the tests.")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts == ["to run the tests."])
        #expect(rig.captured.insertedText == nil)
        #expect(rig.hub.current == "claude:s2")
    }

    @Test func aLeadingNameWithoutTellSendsTheRestToThatConversation() async {
        let rig = await rig("keyscribe what is going on with this right now?", current: "claude:s2")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["what is going on with this right now?"])
        #expect(rig.hub.current == "claude:s1")
    }

    @Test func equallyStrongAddressesSendToTheAlphabeticallyFirstMatch() async {
        let rig = await rig("Tell blue, run the tests.", current: "claude:s1",
                      namesFile: #"{"schema_version":1,"names":{"claude:s1":"web blue","claude:s2":"api blue"}}"#)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts == ["run the tests."])
        #expect(rig.hub.current == "claude:s2")
    }

    @Test(arguments: ["Session to run the build", "Keyscrib run the tests"])
    func aMisheardAddressWithoutTellSendsNothingToTheCurrentConversation(transcript: String) async {
        let rig = await rig(transcript, current: "claude:s2")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
        #expect(rig.hub.current == "claude:s2")
    }

    @Test func aWordThatSoundsLikeTheCurrentConversationSendsTheWholeTakeThere() async {
        let rig = await rig("Keyscrib run the tests", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["Keyscrib run the tests"])
    }

    @Test func aSpokenNameIsNotReplacedByTheCurrentConversationItSoundsLike() async {
        let rig = await rig("Tell keyscribe glue the adapters together", current: "claude:s2")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["glue the adapters together"])
    }

    private static let twoFirst = #"{"schema_version":1,"names":{"claude:s1":"two","claude:s2":"zeta"}}"#

    @Test func aSentenceStartingWithANumberNameGoesWholeToTheCurrentConversation() async {
        let rig = await rig("Two tests failed.", current: "claude:s2", namesFile: Self.twoFirst)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts == ["Two tests failed."])
    }

    @Test func tellReachesANumberNameAtADifferentRowAndSessionReachesTheRow() async {
        let told = await rig("Tell two, run tests.", current: "claude:s2", namesFile: Self.twoFirst)
        defer { try? FileManager.default.removeItem(at: told.supportDir) }
        await take(told)
        #expect(told.sent.map(\.1) == ["claude:s1"])
        #expect(told.texts == ["run tests."])

        let row = await rig("Session two, run tests.", current: "claude:s1", namesFile: Self.twoFirst)
        defer { try? FileManager.default.removeItem(at: row.supportDir) }
        await take(row)
        #expect(row.sent.map(\.1) == ["claude:s2"])
        #expect(row.texts == ["run tests."])
    }

    @Test func openingANumberNoConversationHasHoldsAndSaysSo() async {
        let focus = Focus()
        let rig = await rig("Open two.", current: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(focus.sessions.isEmpty)
        #expect(rig.hub.current == "claude:s1")
        #expect(rig.hud.states.contains { if case .error(let message, _, _) = $0 { message == "No conversation named \u{201C}two\u{201D}. Try \u{201C}open keyscribe\u{201D}" } else { false } })
    }

    @Test func sessionBeforeANameAddressesThatConversation() async {
        let rig = await rig("Session keyscribe blue, run unit tests.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts == ["run unit tests."])
    }

    @Test func openSessionAndANameOpensThatConversation() async {
        let focus = Focus()
        let rig = await rig("Open session keyscribe blue", current: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(focus.sessions == ["claude:s2"])
    }

    @Test func anUnaddressedTakeGoesToTheCurrentRecipient() async {
        let rig = await rig("Run the tests.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.captured.insertedText == nil)
    }

    private func inFront(
        _ transcript: String = "Run the tests.", modes: [Mode]? = nil, press: TargetSnapshot = terminal,
        glance: any AgentFronting = Front("claude:s2"), engine: (any SpeechEngine)? = nil, frontGrace: Duration = .seconds(1)
    ) async -> Rig {
        await rig(transcript, modes: modes, current: "claude:s1", front: FrontWindow(press), glance: glance, engine: engine, frontGrace: frontGrace)
    }

    @Test func anUnaddressedTakeGoesToTheConversationInFrontAndMakesItCurrent() async {
        let rig = await inFront()
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.hub.current == "claude:s2")
        let roster = try? #require(rosters(rig).last ?? nil)
        #expect(roster?.rows.map(\.name) == ["keyscribe", "keyscribe blue"])
        #expect(roster?.recipientName == "keyscribe blue")
        #expect(roster?.source == .front)
        #expect(fact(await lastHistoryEntry(rig), "Chosen by") == "The conversation in front")
    }

    @Test func aSpokenNameWinsOverTheConversationInFront() async {
        let rig = await inFront("Tell keyscribe to run the tests.")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.hub.current == "claude:s1")
    }

    @Test func aSpokenNameDoesNotWaitForTheFrontReading() async {
        let slow = SlowFront()
        let rig = await inFront("Tell keyscribe to run the tests.", glance: slow, frontGrace: .seconds(30))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        slow.release.fire()
        #expect(rig.sent.map(\.1) == ["claude:s1"])
    }

    @Test func aFixedConversationIgnoresTheConversationInFront() async {
        let rig = await inFront(modes: [agentMode(target: .handle("keyscribe"))])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
    }

    @Test func thePressNeverReadsTheFrontThroughTheReaderThatMayAskForAccess() async {
        let rig = await rig("Run the tests.", current: "claude:s1", front: FrontWindow(Self.terminal), sessionInFront: Front("claude:s2"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
    }

    @Test(arguments: [
        TargetSnapshot(bundleId: "com.apple.Safari", pid: 4, focusedWindowId: "cg:3"),
        TargetSnapshot(bundleId: "com.mitchellh.ghostty", pid: 9, focusedWindowId: "cg:5"),
    ])
    func aFrontReadingFromAnotherAppOrWindowThanThePressLeavesTheCurrentRecipient(press: TargetSnapshot) async {
        let rig = await inFront(press: press)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.hub.current == "claude:s1")
    }

    @Test func aConversationInFrontThatIsNotInTheListLeavesTheCurrentRecipient() async {
        let rig = await inFront(glance: Front("claude:s9"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
    }

    @Test func aFrontReadingThatDoesNotSettleInTimeLeavesTheCurrentRecipient() async {
        let slow = SlowFront()
        let rig = await inFront(glance: slow, frontGrace: .milliseconds(50))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        slow.release.fire()
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.hub.current == "claude:s1")
    }

    @Test func aFrontReadingThatLandsAfterReleaseAndGraceWhileTranscribingIsIgnored() async {
        let slow = SlowFront()
        let engine = BlockedEngine()
        let rig = await inFront(glance: slow, engine: engine, frontGrace: .milliseconds(50))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        try? await Task.sleep(for: .milliseconds(150))
        slow.release.fire()
        await rig.controller.agentFrontTask?.value
        engine.release.fire()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.hub.current == "claude:s1")
    }

    @Test func aFrontReadingThatLandsAfterItsTakeWasCancelledNeverReachesTheNextTake() async {
        let slow = SlowFront()
        let rig = await inFront(glance: slow)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        let first = rig.controller.agentFrontTask
        rig.controller.cancel()
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        await rig.controller.agentFrontTask?.value
        slow.release.fire()
        await first?.value
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.map(\.1) == ["claude:s1"])
    }

    @Test func anUnknownNameSendsNothingAndInsertsNothing() async {
        let rig = await rig("Tell frontend to run the tests.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
        #expect(rig.hub.current == "claude:s1")
    }

    @Test func whileNamesCannotBeLoadedASpokenNameSendsNothing() async {
        let rig = await rig("Tell keyscribe blue to run the tests.", current: "claude:s1", namesFile: "not json")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
        #expect(rig.hub.directory.conversations.isEmpty)
        #expect(rosters(rig).compactMap { $0 }.last?.namesAvailable == false)
    }

    @Test(arguments: ["Tell my api to run the tests.", "Tell the api to run the tests."])
    func whileNamesCannotBeLoadedANameThatReadsLikeProseStillSendsNothing(transcript: String) async {
        let rig = await rig(transcript, current: "claude:s1", namesFile: "not json")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
    }

    @Test func whileSavedChoicesCannotBeLoadedEvenARowNumberSendsNothing() async {
        let rig = await rig("Tell session 2 to run the tests.", current: "claude:s1", namesFile: "not json")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
    }

    @Test func withTheFeatureOffNothingIsSent() async {
        let rig = await rig("Tell keyscribe to run the tests.", enabled: false)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
    }

    @Test func theAddressIsReadBeforeTheTextStagesWhichThenApplyToTheMessageOnly() async {
        var mode = agentMode()
        mode.replacements = .init(includeGlobal: false, rules: [
            .init(heard: "keyscribe blue", replace: "keyscribe", regex: false),
            .init(heard: "tests", replace: "specs", regex: false),
        ])
        let rig = await rig("Tell keyscribe blue to run the tests.", modes: [mode])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts == ["to run the specs."])
    }

    @Test func aNameTheReplacementsCorrectIsOpened() async {
        var mode = agentMode()
        mode.replacements = .init(includeGlobal: false, rules: [.init(heard: "Keys Crab", replace: "keyscribe", regex: false)])
        let focus = Focus()
        let rig = await rig("Go to Keys Crab Blue.", modes: [mode], current: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(focus.sessions == ["claude:s2"])
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.current == "claude:s2")
    }

    @Test func aLiveEditRightAfterACorrectedNameReachesTheMessage() async {
        var mode = agentMode()
        mode.replacements = .init(includeGlobal: false, rules: [.init(heard: "Keys Crab", replace: "keyscribe", regex: false)])
        let rig = await rig("Tell Keys Crab Blue insert new line hello", modes: [mode], current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts == ["\nhello"])
    }

    private func slashResumeMode() -> Mode {
        var mode = agentMode()
        mode.replacements = .init(includeGlobal: false, rules: [.init(heard: "slash resume", replace: "/resume", regex: false)])
        return mode
    }

    @Test func aWholeUtteranceRuleAfterANameIsSentToThatConversationAsWritten() async {
        let rig = await rig("tell keyscribe blue slash resume", modes: [slashResumeMode()], current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts == ["/resume"])
    }

    @Test func aTakeThatIsAWholeUtteranceRuleGoesToTheCurrentConversation() async {
        let rig = await rig("slash resume", modes: [slashResumeMode()], current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["/resume"])
    }

    @Test func verbatimTextThatStartsWithTellIsNeverAnAddress() async {
        let rig = await rig("begin verbatim tell keyscribe blue to stop end verbatim", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts.first?.contains("tell keyscribe blue to stop") == true)
        #expect(rig.hub.current == "claude:s1")
    }

    @Test func skippingASlowRewriteSendsTheLocalTextToTheAgentAndNeverPastes() async {
        var mode = agentMode()
        mode.aiRewrite = .init(connection: "c", prompt: "Tidy it.")
        let llm = HangingLLM()
        let rig = await rig(
            "Tell keyscribe blue to run the tests.", modes: [mode],
            connection: Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k"), llm: llm)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        await llm.started.wait()
        rig.controller.insertLocalTranscriptNow()
        llm.release.fire()
        for _ in 0..<200 where rig.controller.isBusy { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(rig.captured.insertedText == nil)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts == ["to run the tests."])
    }

    @Test func aSkipCancelledBeforeItRunsNeverReachesTheNextTake() async {
        var mode = agentMode()
        mode.aiRewrite = .init(connection: "c", prompt: "Tidy it.")
        let llm = HangingLLM()
        let rig = await rig(
            "Tell keyscribe blue to run the tests.", modes: [mode],
            connection: Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k"), llm: llm)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        await llm.started.wait()
        rig.controller.insertLocalTranscriptNow()
        rig.controller.cancel()
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        for _ in 0..<20 { await Task.yield() }
        llm.release.fire()

        #expect(rig.sent.isEmpty)
        #expect(rig.controller.isBusy)
        #expect(!rig.hud.states.contains { $0.primaryText == "Not sent: the recipient was lost" })
    }

    @Test func aSkipDuringTheReasoningLookupKeepsTheSkipInTheRecord() async {
        var mode = agentMode()
        mode.aiRewrite = .init(connection: "c", prompt: "Tidy it.")
        let llm = SlowReasoningLLM()
        let rig = await rig(
            "Tell keyscribe blue to run the tests.", modes: [mode],
            connection: Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k"), llm: llm)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        await llm.asked.wait()
        let rewriting = rig.controller.dictationTask
        rig.transport.confirms = false
        rig.controller.insertLocalTranscriptNow()
        for _ in 0..<200 where rig.sent.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        llm.release.fire()
        await rewriting?.value
        let request = try? #require(rig.sent.first).0.id
        rig.hub.handle(.submitted(request: request ?? "", turn: ""))
        for _ in 0..<200 where rig.controller.isBusy { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(rig.controller.lastRecord?.fallbackReason == "skipped by the user")
        #expect(rig.controller.lastRecord?.fingerprints[.llmOut] == nil)
        #expect(rig.texts == ["to run the tests."])
    }

    @Test func cancellingWhileTheMessageIsBeingSentKeepsTheTruthfulReceipt() async {
        let rig = await rig("Run the tests.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.confirms = false
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        for _ in 0..<200 where rig.sent.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(rig.sent.count == 1)

        rig.controller.cancel()
        rig.hub.handle(.submitted(request: rig.sent[0].0.id, turn: ""))
        await rig.controller.dictationTask?.value
        for _ in 0..<200 where rig.controller.isBusy { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(rig.hud.states.contains(.commandDone(summary: "Sent to keyscribe", detail: "Coding agent")))
        #expect(rig.hud.states.last != .hidden)
    }

    @Test func aSpokenPhraseNeverTurnsADictationIntoAnAgentMessage() async {
        var plain = Mode(id: "plain", name: "Plain")
        plain.output = .cursor
        var agent = agentMode()
        agent.triggerPhrases = ["over to agents"]
        let rig = await rig("Tell keyscribe blue to run the tests over to agents", modes: [plain, agent])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, mode: "plain")
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText?.hasPrefix("Tell keyscribe blue to run the tests over to agents") == true)
    }

    @Test func silenceSendsNothingAndAsksNothing() async {
        let rig = await rig("", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(!rig.hud.states.contains { if case .error = $0 { true } else { false } })
    }

    @Test func aTakeTheTimeLimitCutsOffIsNeverSentToTheAgent() async {
        let rig = await rig("run the tests", current: "claude:s1", maxRecordingSeconds: 0.05)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        let stopped = { rig.hud.states.contains { if case .error(let message, _, _) = $0 { message.hasPrefix("Stopped at the ") } else { false } } }
        for _ in 0..<400 where !stopped() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await rig.controller.dictationTask?.value
        #expect(stopped())
        #expect(rig.sent.isEmpty)
        #expect(rig.controller.lastResult == "run the tests")
    }

    @Test func aNameHeardAfterTheMicrophoneStoppedSelectsNothing() async {
        let rig = await rig("Tell keyscribe blue.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.audio.loseCapture()
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.hub.current == "claude:s1")
        #expect(rig.hud.states.contains(.error(message: "The microphone stopped, so the command did not run.", action: nil)))
    }

    @Test func aMessageToANamedConversationAfterTheMicrophoneStoppedNeitherSendsNorSwitches() async {
        let rig = await rig("Tell keyscribe blue to run the tests.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.audio.loseCapture()
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.current == "claude:s1")
    }

    @Test func aNameAloneSelectsWithoutSending() async {
        let rig = await rig("Tell keyscribe blue.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.current == "claude:s2")
    }

    final class Focus: AgentTerminalFocusing, @unchecked Sendable {
        var sessions: [String] = []
        let result: AgentFocusResult
        let askingApp: String?
        var whileFocusing: @MainActor @Sendable () -> Void = {}
        init(_ result: AgentFocusResult = .exact, asking: String? = nil) {
            self.result = result
            askingApp = asking
        }
        func focus(
            session: String, pid: Int, environment: [String: String], stillWanted: @escaping @MainActor @Sendable () -> Bool,
            asking: @escaping @MainActor @Sendable (String) -> Void
        ) async -> AgentFocusResult {
            sessions.append(session)
            if let askingApp { await asking(askingApp) }
            await whileFocusing()
            return result
        }
    }

    @Test func anOpenThatCameForwardWithoutSelectingTheTabInTheSameWindowRecordsNothing() async {
        let runner = BackRunner()
        let rig = await rig("Switch to keyscribe blue.", current: "claude:s1", voiceCommands: runner, focus: Focus(.app("Ghostty")),
                      front: FrontWindow(Self.terminal), sessionInFront: Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(runner.recorded.isEmpty)
    }

    @Test func anOpenCancelledWhileItMovesFocusRecordsNoReturnDestination() async {
        let runner = BackRunner()
        let front = FrontWindow(Self.textEdit)
        let focus = Focus()
        let rig = await rig("Switch to keyscribe blue.", current: "claude:s1", voiceCommands: runner, focus: focus, front: front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let controller = rig.controller
        focus.whileFocusing = {
            front.snapshot = Self.terminal
            controller.cancel()
        }
        await take(rig)
        #expect(focus.sessions == ["claude:s2"])
        #expect(runner.recorded.isEmpty)
    }

    @Test func aSessionReadInAnotherAppThanThePressIsNotAttachedToThatWindow() async {
        let runner = BackRunner()
        let front = FrontWindow(Self.textEdit)
        let rig = await rig("Switch to keyscribe blue.", current: "claude:s1", voiceCommands: runner, focus: Focus(), front: front, sessionInFront: Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        front.snapshot = Self.terminal
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(runner.recorded == [VoiceCommandOrigin(bundleId: "com.apple.TextEdit", pid: 42, windowId: "cg:7")])
    }

    @Test func turningCodingAgentsOffWhileGoingBackLeavesTheControllerFreeForTheNextTake() async {
        let runner = BackRunner()
        let rig = await rig("go back", current: "claude:s1", voiceCommands: runner, focus: Focus())
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let controller = rig.controller
        runner.whileRunning = {
            var settings = controller.settings
            settings.features.setEnabled(false, for: .codingAgents)
            controller.updateSettings(settings)
        }
        await take(rig)
        #expect(!rig.controller.isBusy)
        #expect(rig.hud.states.last == .hidden)
        #expect(!rig.hud.states.contains(.commandDone(summary: "TextEdit")))
        var settings = controller.settings
        settings.features.setEnabled(true, for: .codingAgents)
        controller.updateSettings(settings)
        runner.whileRunning = {}
        await take(rig)
        #expect(runner.ran.count == 2)
        #expect(rig.hud.states.contains(.commandDone(summary: "TextEdit")))
    }

    @Test func systemSleepAndTurningCodingAgentsOffCloseARunningTerminalScriptGateAtOnce() async {
        let rig = await rig("", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let sleeping = StopGate.watching({ true }, every: .seconds(10))
        rig.controller.handleSystemSleep()
        #expect(!sleeping.isOpen)
        await sleeping.finish()
        let disabled = StopGate.watching({ true }, every: .seconds(10))
        var settings = rig.controller.settings
        settings.features.setEnabled(false, for: .codingAgents)
        rig.controller.updateSettings(settings)
        #expect(!disabled.isOpen)
        await disabled.finish()
    }

    @Test func aSessionWhoseWindowCannotBeReadIsNotAttachedToACapturedWindow() async {
        let runner = BackRunner()
        let rig = await rig("Switch to keyscribe blue.", current: "claude:s1", voiceCommands: runner, focus: Focus(),
                      front: FrontWindow(Self.terminal), sessionInFront: Front("claude:s1", window: nil))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(runner.recorded.isEmpty)
    }

    @Test func systemSleepWhileGoingBackOnTheCodingAgentTriggerStopsTheReturn() async {
        let runner = BackRunner()
        let rig = await rig("go back", current: "claude:s1", voiceCommands: runner, focus: Focus())
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let controller = rig.controller
        runner.whileRunning = { controller.handleSystemSleep() }
        await take(rig)
        #expect(!rig.controller.isBusy)
        #expect(!rig.hud.states.contains(.commandDone(summary: "TextEdit")))
        #expect(rig.history.entries().isEmpty)
    }

    nonisolated private static let textEdit = TargetSnapshot(bundleId: "com.apple.TextEdit", pid: 42, focusedWindowId: "cg:7")
    nonisolated private static let terminal = TargetSnapshot(bundleId: "com.mitchellh.ghostty", pid: 9, focusedWindowId: "cg:3")

    @Test(arguments: [AgentFocusResult.exact, .app("Ghostty"), .unsupported("kitty")])
    func openingAConversationThatMovedFocusRecordsWhereTheUserWasForGoBack(result: AgentFocusResult) async {
        let runner = BackRunner()
        let front = FrontWindow(Self.textEdit)
        let focus = Focus(result)
        focus.whileFocusing = { front.snapshot = Self.terminal }
        let rig = await rig("Switch to keyscribe blue.", current: "claude:s1", voiceCommands: runner, focus: focus, front: front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(focus.sessions == ["claude:s2"])
        #expect(runner.recorded == [VoiceCommandOrigin(bundleId: "com.apple.TextEdit", pid: 42, windowId: "cg:7")])
        #expect(runner.ran.isEmpty)
    }

    @Test func openingFromAnotherSessionInTheSameWindowRecordsThatSessionAsTheReturn() async {
        let runner = BackRunner()
        let rig = await rig("Switch to keyscribe blue.", current: "claude:s1", voiceCommands: runner, focus: Focus(),
                      front: FrontWindow(Self.terminal), sessionInFront: Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(runner.recorded == [VoiceCommandOrigin(bundleId: "com.mitchellh.ghostty", pid: 9, windowId: "cg:3", session: "claude:s1")])
    }

    @Test func aSessionShownInAnotherWindowOfThePressedTerminalIsNotAttachedToThatWindow() async {
        let runner = BackRunner()
        let rig = await rig("Switch to keyscribe blue.", current: "claude:s1", voiceCommands: runner, focus: Focus(),
                      front: FrontWindow(Self.terminal), sessionInFront: Front("claude:s1", window: "cg:5"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(runner.recorded.isEmpty)
    }

    @Test func openingTheConversationAlreadyShownRecordsNoReturnDestination() async {
        let runner = BackRunner()
        let rig = await rig("Switch to keyscribe blue.", current: "claude:s1", voiceCommands: runner, focus: Focus(),
                      front: FrontWindow(Self.terminal), sessionInFront: Front("claude:s2"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(runner.recorded.isEmpty)
    }

    @Test func theRunnerCanReturnToSessionsThroughTheHubWithoutChangingTheRecipient() async {
        let runner = BackRunner()
        let focus = Focus()
        let rig = await rig("", current: "claude:s1", voiceCommands: runner, focus: focus, sessionInFront: Front("claude:s2"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let sessions = try? #require(runner.sessions)
        #expect(await sessions?.inFront() == FrontSession(id: "claude:s2", app: FrontApp(bundle: "com.mitchellh.ghostty", pid: 9, name: "Ghostty", window: "cg:3")))
        #expect(sessions?.handle("claude:s2") == "keyscribe blue")
        #expect(await sessions?.open("claude:s2", { true }) == .exact)
        #expect(focus.sessions == ["claude:s2"])
        #expect(rig.hub.current == "claude:s1")
    }

    @Test func withCodingAgentsOffTheRunnerHasNoSessionsToReturnTo() async {
        let runner = BackRunner()
        let rig = await rig("", current: "claude:s1", enabled: false, voiceCommands: runner, focus: Focus(), sessionInFront: Front("claude:s2"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        #expect(await runner.sessions?.inFront() == nil)
        #expect(await runner.sessions?.open("claude:s2", { true }) == AgentFocusResult.none)
        #expect(runner.sessions?.handle("claude:s2") == nil)
    }

    @Test func openingAConversationAlreadyInFrontKeepsTheEarlierReturnDestination() async {
        let runner = BackRunner()
        let rig = await rig("Switch to keyscribe blue.", current: "claude:s1", voiceCommands: runner, focus: Focus(), front: FrontWindow(Self.terminal))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.hub.current == "claude:s2")
        #expect(runner.recorded.isEmpty)
    }

    @Test func anOpenThatBroughtNothingForwardRecordsNoReturnDestination() async {
        let runner = BackRunner()
        let front = FrontWindow(Self.textEdit)
        let focus = Focus(.none)
        focus.whileFocusing = { front.snapshot = Self.terminal }
        let rig = await rig("Switch to keyscribe blue.", current: "claude:s1", voiceCommands: runner, focus: focus, front: front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(runner.recorded.isEmpty)
    }

    @Test func goBackOnTheCodingAgentTriggerReturnsLocallyAndSendsNothing() async {
        let runner = BackRunner()
        let focus = Focus()
        let rig = await rig("Go back.", current: "claude:s1", voiceCommands: runner, focus: focus, front: FrontWindow(Self.terminal))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(runner.ran.map(\.transcript) == ["go back"])
        #expect(runner.ran.first?.origin == VoiceCommandOrigin(bundleId: "com.mitchellh.ghostty", pid: 9, windowId: "cg:3"))
        #expect(rig.sent.isEmpty)
        #expect(focus.sessions.isEmpty)
        #expect(rig.hub.current == "claude:s1")
        #expect(rig.hud.states.contains(.commandDone(summary: "TextEdit")))
        #expect(entry?.summary == "Returns to TextEdit.")
        #expect(entry?.outcome == .inserted)
        #expect(fact(entry, "Command") == "Go back")
        #expect(fact(entry, "Default recipient") == "keyscribe")
    }

    @Test(arguments: ["Repeat that.", "say that again"])
    func repeatThatOnTheCodingAgentTriggerReplaysLocallyAndSendsNothing(text: String) async {
        let runner = BackRunner()
        runner.outcome = .done(summary: "docs", command: "Replays the last spoken reply.")
        let rig = await rig(text, current: "claude:s1", voiceCommands: runner)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(runner.ran.map(\.transcript) == ["repeat that"])
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.current == "claude:s1")
        #expect(entry?.outcome == .inserted)
        #expect(fact(entry, "Command") == "Repeat that")
        #expect(fact(entry, "Default recipient") == "keyscribe")
    }

    @Test func renamingThisSessionRenamesTheCurrentConversationAndSendsNothing() async {
        let rig = await rig("Rename this session to Auth Refactor 2.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.handle(of: "claude:s1") == "auth refactor two")
        #expect(rig.hub.handle(of: "claude:s2") == "keyscribe blue")
        #expect(rig.hub.current == "claude:s1")
        #expect(rig.hud.states.contains(.commandDone(summary: "Renamed keyscribe to auth refactor two", detail: "Coding agent")))
        #expect(entry?.outcome == .inserted)
        #expect(fact(entry, "Command") == "Rename")
        #expect(fact(entry, "New name") == "auth refactor two")
        #expect(fact(entry, "Chosen by") == "The current conversation")
    }

    @Test func renamingThisSessionRenamesTheConversationInFrontAndMakesItCurrent() async {
        let rig = await inFront("Rename this session to docs")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.handle(of: "claude:s2") == "docs")
        #expect(rig.hub.handle(of: "claude:s1") == "keyscribe")
        #expect(rig.hub.current == "claude:s2")
        #expect(fact(await lastHistoryEntry(rig), "Chosen by") == "The conversation in front")
    }

    @Test func aRenameIsSavedForTheNextLaunch() async {
        let rig = await rig("Rename this session to docs", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let saved = try? String(contentsOf: rig.supportDir.appendingPathComponent("agents").appendingPathComponent(AgentNameStore.fileName), encoding: .utf8)
        #expect(saved?.contains("docs") == true)
    }

    @Test(arguments: [
        ("Rename this session to keyscribe blue", "Another conversation is already called \u{201C}keyscribe blue\u{201D}"),
        ("Rename this session to session 3", "\u{201C}Session\u{201D} followed by a number is how you say a row, so it cannot be a name"),
    ])
    func aRenameThatCannotTakeTheNameKeepsTheOldOne(text: String, message: String) async {
        let rig = await rig(text, current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.handle(of: "claude:s1") == "keyscribe")
        #expect(rig.hud.states.contains { if case .error(let shown, _, _) = $0 { shown == message } else { false } })
        #expect(entry?.outcome == .failed)
        #expect(fact(entry, "Command") == "Rename")
    }

    @Test func aRenameWithNoCurrentConversationSaysSoAndRenamesNothing() async {
        let rig = await rig("Rename this session to docs")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.handle(of: "claude:s1") == "keyscribe")
        #expect(rig.hub.handle(of: "claude:s2") == "keyscribe blue")
        #expect(rig.hud.states.contains(.error(
            message: "Switch to a conversation, then say the rename command again", action: .openCodingAgents(Mode.codingAgentId),
            heard: HeardExcerpt(heard: "Rename this session to docs"))))
    }

    @Test(arguments: [
        ("Rename this session to", "Say \u{201C}rename this session to\u{201D} and the new name. Nothing was sent"),
        ("Rename this session to the one we used for the parser yesterday", "A name can be up to 4 words. Nothing was sent"),
        ("Rename this session to docs. Run the tests.", "Say only the new name after \u{201C}rename this session to\u{201D}. Nothing was sent"),
    ])
    func aRenameWithoutAUsableNameIsHeldAndSendsNothing(text: String, message: String) async {
        let rig = await rig(text, current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.handle(of: "claude:s1") == "keyscribe")
        #expect(rig.hud.states.contains { if case .error(let shown, _, _) = $0 { shown == message } else { false } })
        #expect(entry?.outcome == .failed)
        #expect(fact(entry, "Command") == "Rename")
    }

    @Test(arguments: ["Rename this session to docs. Never mind.", "Rename this session. Never mind."])
    func neverMindAfterARenameThrowsTheTakeAway(text: String) async {
        let rig = await rig(text, current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.handle(of: "claude:s1") == "keyscribe")
        #expect(rig.hud.states.contains(.advisory(message: DictationController.discardedMessage)))
        #expect(!rig.hud.states.contains { if case .error = $0 { true } else { false } })
        #expect(await lastHistoryEntry(rig) == nil)
    }

    @Test(arguments: [
        "Rename this session to docs, scratch that, notes.",
        "Rename this session to docs, scratch that. Rename this session to notes.",
    ])
    func scratchThatInsideARenameCorrectsTheName(text: String) async {
        let rig = await rig(text, current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.handle(of: "claude:s1") == "notes")
    }

    @Test func replacementsApplyToTheNameButNeverToTheRenameCommand() async {
        var mode = agentMode()
        mode.replacements = .init(includeGlobal: false, rules: [
            .init(heard: "this session", replace: "the session", regex: false),
            .init(heard: "Keys Crab", replace: "keyscribe", regex: false),
        ])
        let rig = await rig("Rename this session to Keys Crab docs", modes: [mode], current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.handle(of: "claude:s1") == "keyscribe docs")
    }

    @Test func turningCodingAgentsOffWhileFindingTheConversationInFrontRenamesNothing() async {
        let slow = SlowFront()
        let rig = await inFront("Rename this session to docs", glance: slow, frontGrace: .seconds(30))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        try? await Task.sleep(for: .milliseconds(150))
        var settings = rig.controller.settings
        settings.features.setEnabled(false, for: .codingAgents)
        rig.controller.updateSettings(settings)
        slow.release.fire()
        await rig.controller.dictationTask?.value
        #expect(rig.hub.handle(of: "claude:s1") == "keyscribe")
        #expect(rig.hub.handle(of: "claude:s2") == "keyscribe blue")
        #expect(!rig.controller.isBusy)
    }

    @Test(arguments: [
        ("Tell keyscribe rename this session to docs", "rename this session to docs"),
        ("Rename this to parseConfig", "Rename this to parseConfig"),
    ])
    func renameWordsInsideAMessageAreStillAMessage(text: String, sent: String) async {
        let rig = await rig(text, current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.texts == [sent])
        #expect(rig.hub.handle(of: "claude:s1") == "keyscribe")
    }

    @Test func goBackWithNothingToReturnToSaysSoAndSendsNothing() async {
        let runner = BackRunner()
        runner.outcome = .failed(message: "Nothing to go back to.")
        let rig = await rig("go back", current: "claude:s1", voiceCommands: runner)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains { if case .error(let message, _, _) = $0 { message == "Nothing to go back to." } else { false } })
        #expect(entry?.outcome == .failed)
        #expect(entry?.failureReason == "Nothing to go back to.")
    }

    @Test(arguments: [
        ("Tell keyscribe go back", "go back"), ("Go back to the parser", "Go back to the parser"),
        ("Tell keyscribe repeat that", "repeat that"), ("Repeat that test run", "Repeat that test run"),
    ])
    func goBackInsideAMessageIsStillAMessage(text: String, sent: String) async {
        let runner = BackRunner()
        let rig = await rig(text, current: "claude:s1", voiceCommands: runner)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.texts == [sent])
        #expect(runner.ran.isEmpty)
    }

    @Test func openingAConversationBringsItForwardAndSendsNothing() async {
        let focus = Focus()
        let rig = await rig("Switch to keyscribe blue.", current: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(focus.sessions == ["claude:s2"])
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
        #expect(rig.hub.current == "claude:s2")
        #expect(rig.hud.states.contains(.commandDone(summary: "Opened keyscribe blue", detail: "Coding agent")))
    }

    @Test(arguments: [AgentFocusResult.app("Ghostty"), .unsupported("kitty"), .notAllowed("Ghostty"), .none])
    func aConversationWhoseTerminalWasNotSelectedIsStillCurrentAndTheHUDSaysSo(result: AgentFocusResult) async {
        let rig = await rig("Open keyscribe blue.", current: "claude:s1", focus: Focus(result))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.current == "claude:s2")
        #expect(rig.hud.states.contains(result.hudState(handle: "keyscribe blue", detail: "Coding agent")))
        #expect(!rig.hud.states.contains { if case .commandDone = $0 { true } else { false } })
    }

    final class HeldFocus: AgentTerminalFocusing, @unchecked Sendable {
        var started = false
        var released = false
        var asked = false
        func focus(
            session: String, pid: Int, environment: [String: String], stillWanted: @escaping @MainActor @Sendable () -> Bool,
            asking: @escaping @MainActor @Sendable (String) -> Void
        ) async -> AgentFocusResult {
            started = true
            while !released { try? await Task.sleep(for: .milliseconds(5)) }
            await asking("Ghostty")
            asked = true
            return .exact
        }
    }

    @Test func aCancelledOpenNeverShowsThePermissionHintAfterwards() async {
        let focus = HeldFocus()
        let rig = await rig("Open keyscribe blue.", current: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        for _ in 0..<200 where !focus.started { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(focus.started)
        rig.controller.cancel()
        focus.released = true
        await rig.controller.dictationTask?.value
        for _ in 0..<200 where !focus.asked { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(focus.asked)
        #expect(!rig.hud.states.contains { if case .transcribing(_, let status?) = $0 { status.hasPrefix("Allow access") } else { false } })
    }

    @Test func whileATerminalIsBeingFoundTheHUDSaysWhichConversationIsOpening() async {
        let rig = await rig("Open keyscribe blue.", current: "claude:s1", focus: Focus())
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.hud.states.contains(.transcribing(mode: "Coding agent", status: "Opening keyscribe blue\u{2026}")))
    }

    @Test func whileATerminalAsksForPermissionTheHUDSaysWhatItIsFor() async {
        let focus = Focus(.exact, asking: "Ghostty")
        let rig = await rig("Open keyscribe blue.", current: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.hud.states.contains(.transcribing(mode: "Coding agent", status: "Allow access to Ghostty to open the tab for keyscribe blue")))
    }

    @Test func anOpenVerbFollowedByAnInstructionIsSentAsSaid() async {
        let focus = Focus()
        let rig = await rig("Open the readme and fix the typo.", current: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(focus.sessions.isEmpty)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["Open the readme and fix the typo."])
    }

    @Test func turningTheFeatureOffDuringARewriteEndsTheTakeAndKeepsTheText() async {
        var mode = agentMode()
        mode.aiRewrite = .init(connection: "c", prompt: "Tidy it.")
        let llm = HangingLLM()
        let rig = await rig(
            "Tell keyscribe blue to run the tests.", modes: [mode],
            connection: Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k"), llm: llm)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        await llm.started.wait()

        var off = Settings.defaults
        off.stt = .init(engine: "fixed", eviction: .frugal)
        off.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        rig.controller.updateSettings(off)
        rig.controller.agents = nil
        llm.release.fire()
        await rig.controller.dictationTask?.value

        #expect(!rig.controller.isBusy)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
        #expect(rig.controller.lastResult == "rewritten")
        #expect(rig.hud.states.contains { if case .error = $0 { true } else { false } })
    }

    @Test func aBackgroundReceiptWaitsForAPendingChoiceThenShows() async {
        let runner = ChoiceRunner()
        runner.pendingChoice = VoiceCommandPendingChoice(
            id: 1, choice: VoiceCommandChoice(family: .navigation, target: "x", matches: []), request: "", origin: nil,
            rows: [], places: [], scripts: [])
        let rig = await rig("", voiceCommands: runner)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let notice = HUDState.error(message: "Not sent: keyscribe isn\u{2019}t connected to \(Branding.appName)", action: nil, heard: nil)

        rig.controller.showAgentNotice(.notSent("keyscribe", reason: .connectorNotRunning))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!rig.hud.states.contains(notice))

        runner.pendingChoice = nil
        for _ in 0..<200 where !rig.hud.states.contains(notice) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(rig.hud.states.contains(notice))
    }

    @Test func noticesThatNeedAttentionAreNotHiddenBehindALaterSuccess() async {
        let runner = ChoiceRunner()
        runner.pendingChoice = VoiceCommandPendingChoice(
            id: 1, choice: VoiceCommandChoice(family: .navigation, target: "x", matches: []), request: "", origin: nil,
            rows: [], places: [], scripts: [])
        let rig = await rig("", voiceCommands: runner)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let uncertainA = HUDState.advisory(message: "May not have reached keyscribe: check its terminal")
        let notSentB = AgentDeliveryWiringTests.notSentNotice("keyscribe blue")
        let sentC = HUDState.commandDone(summary: "Sent to backend", detail: "Coding agent")

        rig.controller.showAgentNotice(.uncertain("keyscribe"))
        rig.controller.showAgentNotice(.notSent("keyscribe blue", reason: .connectorNotRunning))
        rig.controller.showAgentNotice(.sent("backend"))
        runner.pendingChoice = nil

        for _ in 0..<400 where !rig.hud.states.contains(notSentB) { try? await Task.sleep(for: .milliseconds(5)) }
        let shown = rig.hud.states.filter { [uncertainA, notSentB, sentC].contains($0) }
        #expect(shown == [uncertainA, notSentB])
    }

    private static func notSentNotice(_ handle: String) -> HUDState {
        .error(message: "Not sent: \(handle) isn\u{2019}t connected to \(Branding.appName)", action: nil, heard: nil)
    }

    private func lastHistoryEntry(_ rig: Rig) async -> HistoryEntry? {
        rig.controller.waitForHistoryWrites()
        for _ in 0..<50 {
            if let entry = rig.history.entries().first { return entry }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func historyRecordsWhyATakeWasNotSent() async {
        let rig = await rig("Tell frontend to run the tests.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(entry?.failureReason == "Not sent: no conversation named \u{201C}frontend\u{201D}")
    }

    @Test func aConversationWithoutItsConnectorSaysSoRatherThanSuggestingAReload() async {
        let rig = await rig("Run the tests.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.live = false
        rig.hub.refresh()
        await take(rig)
        let expected = "Not sent: keyscribe isn\u{2019}t connected to \(Branding.appName)"
        #expect(rig.hud.states.contains {
            if case .error(expected, .openCodingAgents?, HeardExcerpt(heard: "Run the tests.")) = $0 { true } else { false }
        })
        #expect(await lastHistoryEntry(rig)?.failureReason == expected)
    }

    private func fact(_ entry: HistoryEntry?, _ label: String) -> String? {
        entry?.facts?.first { $0.label == label }?.value
    }

    @Test func historyRecordsAMessageWithWhereItWentAndHowThatWasChosen() async {
        let rig = await rig("Run the tests.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(entry?.summary == "Sent to keyscribe")
        #expect(entry?.result == "Run the tests.")
        #expect(fact(entry, "Command") == "Send message")
        #expect(fact(entry, "Conversation") == "keyscribe \u{00B7} claude \u{00B7} s1")
        #expect(fact(entry, "Chosen by") == "The current conversation")
        #expect(entry?.steps == nil)
    }

    @Test func historyRecordsTheSpokenEditsInAMessageBesideWhereItWent() async {
        var mode = agentMode()
        mode.commands.liveEdits = true
        let rig = await rig("Run the tests insert new line then lint.", modes: [mode], current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(fact(entry, "Conversation") == "keyscribe \u{00B7} claude \u{00B7} s1")
        #expect(fact(entry, "Spoken edits") == "new line")
    }

    @Test func historyRecordsAnOpenAsAnOpenWithNothingSent() async {
        let rig = await rig("Open keyscribe blue.", current: "claude:s1", focus: Focus(.pane(app: "Ghostty", multiplexer: "herdr", uncertain: false)))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(entry?.summary == "Brought Ghostty forward; keyscribe blue\u{2019}s herdr pane not selected")
        #expect(entry?.result == "")
        #expect(fact(entry, "Command") == "Open")
        #expect(fact(entry, "Conversation") == "keyscribe blue \u{00B7} claude \u{00B7} s2")
        #expect(fact(entry, "Default recipient") == "keyscribe")
    }

    @Test func anOpenThatFindsNoConversationIsRecordedAsAnOpen() async {
        let focus = Focus()
        let rig = await rig("Open two.", current: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(focus.sessions.isEmpty)
        #expect(entry?.summary == "No conversation named \u{201C}two\u{201D}")
        #expect(fact(entry, "Command") == "Open")
        #expect(fact(entry, "Spoken address") == "two")
        #expect(fact(entry, "Conversation") == "None resolved")
    }

    @Test(arguments: [
        ("Open frontend.", "No conversation named \u{201C}frontend\u{201D}. Try \u{201C}open keyscribe\u{201D}", "No conversation named \u{201C}frontend\u{201D}"),
        ("Go to key scrub", "\u{201C}key scrub\u{201D} sounded like \u{201C}keyscribe\u{201D}", "\u{201C}key scrub\u{201D} sounded like \u{201C}keyscribe\u{201D}"),
        ("Go to session keyscribe review", "No conversation named \u{201C}keyscribe review\u{201D}. Try \u{201C}open keyscribe\u{201D}", "No conversation named \u{201C}keyscribe review\u{201D}"),
    ])
    func anOpenVerbWithAFewWordsNamingNothingIsHeldAndNeverSent(text: String, line: String, recorded: String) async {
        let focus = Focus()
        let rig = await rig(text, current: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(focus.sessions.isEmpty)
        #expect(rig.hub.current == "claude:s1")
        #expect(rig.hud.states.contains { if case .error(let message, _, _) = $0 { message == line } else { false } })
        #expect(entry?.summary == recorded)
    }

    @Test func anUnknownNameOffersOneRetryWithTheHighlightedConversationAndOpensItsSettings() async {
        let rig = await rig("Tell frontend to run the tests.", current: "claude:s2")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error(let message, .openCodingAgents?, _) = $0 {
                message == "Not sent: no conversation named \u{201C}frontend\u{201D}. Try \u{201C}tell keyscribe blue, \u{2026}\u{201D}"
            } else { false }
        })
        #expect(entry?.failureReason == "Not sent: no conversation named \u{201C}frontend\u{201D}")
    }

    @Test func aQueuedMessageUpdatesItsOwnEntryWhenItIsSentLater() async {
        let rig = await rig("Run the tests.", current: "claude:s1", firstStatus: "busy")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let queued = await lastHistoryEntry(rig)
        #expect(queued?.summary == "Queued for keyscribe")
        #expect(rig.sent.isEmpty)

        rig.registry.firstStatus = "idle"
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        for _ in 0..<200 where rig.history.entries().first?.summary != "Sent to keyscribe" {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        let entries = rig.history.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.id == queued?.id)
        #expect(entries.first?.summary == "Sent to keyscribe")
        #expect(entries.first?.steps?.map(\.text) == ["Queued for keyscribe", "Sent to keyscribe"])
        #expect(entries.first?.facts == queued?.facts)
    }

    @Test func anUncertainDeliveryThatLaterSettlesKeepsTheEarlierUncertainty() async {
        let rig = await rig("Run the tests.", current: "claude:s1", receiptTimeout: .milliseconds(20))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.confirms = false
        await take(rig)
        let uncertain = await lastHistoryEntry(rig)
        #expect(uncertain?.summary == "May not have reached keyscribe: check its terminal")
        #expect(uncertain?.outcome == .failed)

        guard case .submit(let request, _, _, _, _) = rig.sent.first?.0 else { Issue.record("nothing handed off"); return }
        rig.hub.handle(.submitted(request: request, turn: ""))
        for _ in 0..<200 where rig.history.entries().first?.summary != "Sent to keyscribe" {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        let settled = rig.history.entries().first
        #expect(settled?.summary == "Sent to keyscribe")
        #expect(settled?.outcome == .inserted)
        #expect(settled?.failureReason == nil)
        #expect(settled?.steps?.map(\.text) == ["May not have reached keyscribe: check its terminal", "Sent to keyscribe"])
    }

    @Test func aReceiptForADeliveryTheHubForgotNoLongerChangesItsEntry() async {
        let rig = await rig("Run the tests.", current: "claude:s1", receiptTimeout: .milliseconds(20))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.confirms = false
        await take(rig)
        guard case .submit(let request, _, _, _, _) = rig.sent.first?.0 else { Issue.record("nothing handed off"); return }
        rig.controller.forgetAgentReceipt(request: request)
        rig.controller.showAgentNotice(.sent("keyscribe"), request: request)
        try? await Task.sleep(for: .milliseconds(50))
        rig.controller.waitForHistoryWrites()
        let entry = rig.history.entries().first
        #expect(entry?.summary == "May not have reached keyscribe: check its terminal")
        #expect(entry?.steps == nil)
    }

    @Test func withHistoryOffALateReceiptStillShowsAndWritesNothing() async {
        let rig = await rig("Run the tests.", current: "claude:s1", firstStatus: "busy", historyEnabled: false)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        rig.registry.firstStatus = "idle"
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        let sent = HUDState.commandDone(summary: "Sent to keyscribe", detail: "Coding agent")
        for _ in 0..<200 where !rig.hud.states.contains(sent) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(rig.hud.states.contains(sent))
        rig.controller.waitForHistoryWrites()
        #expect(rig.history.entries().isEmpty)
    }

    @Test func aConfirmationRightBehindAnUncertainReceiptStillReachesHistory() async {
        let rig = await rig("Run the tests.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.uncertainThenConfirmed = true
        await take(rig)
        rig.controller.waitForHistoryWrites()
        let entry = await lastHistoryEntry(rig)
        #expect(entry?.summary == "Sent to keyscribe")
        #expect(entry?.outcome == .inserted)
        #expect(entry?.steps?.map(\.text) == ["May not have reached keyscribe: check its terminal", "Sent to keyscribe"])
    }

    @Test func aQueuedMessageWhoseRewriteFellBackKeepsTheFallbackOnceSent() async {
        var mode = agentMode()
        mode.aiRewrite = .init(connection: "c", prompt: "Tidy it.")
        let rig = await rig(
            "Run the tests.", modes: [mode], current: "claude:s1",
            connection: Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k"), llm: FailingLLM(),
            firstStatus: "busy")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let queued = await lastHistoryEntry(rig)
        #expect(queued?.summary == "Queued for keyscribe")
        #expect(queued?.outcome == .localFallback)
        let reason = try? #require(queued?.fallbackReason)

        rig.registry.firstStatus = "idle"
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        for _ in 0..<200 where rig.history.entries().first?.summary != "Sent to keyscribe" {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        let sent = rig.history.entries().first
        #expect(sent?.summary == "Sent to keyscribe")
        #expect(sent?.outcome == .localFallback)
        #expect(sent?.fallbackReason == reason)
    }

    @Test func everyPendingMessageUpdatesItsEntryWhenItIsSent() async {
        let rig = await rig("Run the tests.", current: "claude:s1", firstStatus: "busy")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let count = 25
        for _ in 0..<count { await take(rig) }
        rig.registry.firstStatus = "idle"
        for _ in 0..<count {
            rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
            for _ in 0..<20 { await Task.yield() }
        }
        let sentCount = { rig.history.entries().filter { $0.summary == "Sent to keyscribe" }.count }
        for _ in 0..<400 where sentCount() < count {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        #expect(rig.texts.count == count)
        #expect(sentCount() == count)
    }

    @Test func turningTheBridgeOffStopsUpdatingPendingEntries() async {
        let rig = await rig("Run the tests.", current: "claude:s1", receiptTimeout: .milliseconds(20))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.confirms = false
        await take(rig)
        let uncertain = await lastHistoryEntry(rig)
        guard case .submit(let request, _, _, _, _) = rig.sent.first?.0 else { Issue.record("nothing handed off"); return }

        rig.controller.agents = nil
        rig.controller.showAgentNotice(.sent("keyscribe"), request: request)
        try? await Task.sleep(for: .milliseconds(50))
        rig.controller.waitForHistoryWrites()
        #expect(rig.history.entries().first == uncertain)
    }

    @Test func aSkippedRewriteStaysSkippedAfterAQueuedMessageIsSent() async {
        var mode = agentMode()
        mode.aiRewrite = .init(connection: "c", prompt: "Tidy it.")
        let llm = HangingLLM()
        let rig = await rig(
            "Run the tests.", modes: [mode], current: "claude:s1",
            connection: Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k"), llm: llm,
            firstStatus: "busy")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        await llm.started.wait()
        rig.controller.insertLocalTranscriptNow()
        llm.release.fire()
        for _ in 0..<200 where rig.controller.isBusy { try? await Task.sleep(for: .milliseconds(5)) }
        let queued = await lastHistoryEntry(rig)
        #expect(queued?.summary == "Queued for keyscribe")
        #expect(queued?.outcome == .localFallback)
        #expect(queued?.rewriteSkippedMs != nil)

        rig.registry.firstStatus = "idle"
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        for _ in 0..<200 where rig.history.entries().first?.summary != "Sent to keyscribe" {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        let sent = rig.history.entries().first
        #expect(sent?.summary == "Sent to keyscribe")
        #expect(sent?.outcome == .localFallback)
        #expect(sent?.rewriteSkippedMs == queued?.rewriteSkippedMs)
    }

    @Test func aRefusalAfterAFallenBackRewriteKeepsBothExplanations() async {
        var mode = agentMode()
        mode.aiRewrite = .init(connection: "c", prompt: "Tidy it.")
        let rig = await rig(
            "Run the tests.", modes: [mode], current: "claude:s1",
            connection: Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k"), llm: FailingLLM(),
            firstStatus: "busy")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.confirms = false
        await take(rig)
        let queued = await lastHistoryEntry(rig)
        let reason = try? #require(queued?.fallbackReason)

        rig.registry.firstStatus = "idle"
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        await rig.hub.rescan()
        guard case .submit(let request, _, _, _, _) = rig.sent.first?.0 else { Issue.record("nothing handed off"); return }
        rig.hub.handle(.refused(request: request, reason: "busy elsewhere"))
        for _ in 0..<200 where rig.history.entries().first?.outcome != .failed {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        let refused = rig.history.entries().first
        #expect(refused?.outcome == .failed)
        #expect(refused?.failureReason == "Not sent: keyscribe refused the message")
        #expect(refused.flatMap(whyLocalWasKept) == reason)
    }

    @Test(arguments: [
        (AgentReceipt.KeptReason.composing, "Not sent to docs: it has a message you haven\u{2019}t sent"),
        (.typedSince, "Not sent to docs: you sent it a message since"),
        (.connectionGap, "Not sent to docs: it lost its connection to \(Branding.appName) while this waited"),
    ])
    func aKeptTakeSaysWhyWithoutPromisingToSendLater(reason: AgentReceipt.KeptReason, message: String) {
        #expect(AgentOutput.receiptState(.kept("docs", reason: reason), mode: "Agent", heard: "") == .advisory(message: message))
    }

    @Test(arguments: [
        (AgentDeliveryDecision.QueueReason.working, "Sends when it finishes"),
        (.approval, "Waiting for approval. Say \u{201C}open docs\u{201D} to respond; this message stays queued"),
        (.question, "Waiting for an answer. Say \u{201C}open docs\u{201D} to respond; this message stays queued"),
        (.userDialog, "Dialog open. Say \u{201C}open docs\u{201D} to respond; this message stays queued"),
    ])
    func aQueuedTakeSaysWhatTheConversationIsWaitingOn(reason: AgentDeliveryDecision.QueueReason, detail: String) {
        #expect(AgentOutput.receiptState(.queued("docs", waitingOn: reason), mode: "Agent", heard: "")
            == .commandDone(summary: "Queued for docs", detail: detail))
    }

    @Test func aMessageToAConversationWaitingForApprovalQueuesAndSaysWhy() async {
        let rig = await rig("Run the tests.", current: "claude:s1", firstStatus: "waiting", firstWaitingFor: "permission prompt")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.texts.isEmpty)
        #expect(rig.hud.states.contains(AgentOutput.receiptState(.queued("keyscribe", waitingOn: .approval), mode: "Coding agent", heard: "")))
    }

    private final class Speaker: SpeechSynthesizing {
        var onStarted: (() -> Void)?
        var onFinished: (() -> Void)?
        var isSpeaking = false
        var spoken: [String] = []
        func speak(_ text: String, voice: String?) { spoken.append(text) }
        func stop() {}
    }

    private final class DescribingLLM: LLMClient, @unchecked Sendable {
        var during: @Sendable () async -> Void = {}
        func complete(system: String, user: String, connection: Connection) async throws -> String {
            await during()
            return "Asks whether to allow pushing to main."
        }
    }

    private static let service = Connection(id: "omlx", name: "Local", provider: .openaiCompatible, model: "qwen", keyRef: "k")

    private func speaking(_ rig: Rig, llm: any LLMClient = HTTPLLMClient(), connection: String = "") -> (SpokenResultOutput, Speaker) {
        let speaker = Speaker()
        let output = SpokenResultOutput(
            client: llm, permits: { _ in true }, speech: speaker, silencer: SpeechSilencer(),
            settings: { SpokenResultSettings(enabled: true, connection: connection) },
            connection: { $0 == Self.service.id ? Self.service : nil })
        rig.controller.spokenUpdates = output
        return (output, speaker)
    }

    private func showsAnswer(_ rig: Rig, _ line: String) -> Bool {
        rig.hud.states.contains(.advisory(message: line))
    }

    @Test func aWaitingQuestionAboutANamedConversationIsAnsweredAndSendsNothing() async {
        let rig = await rig("What is keyscribe blue waiting for?", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(showsAnswer(rig, "keyscribe blue is ready for another message."))
        #expect(rig.hub.current == "claude:s1")
        #expect(entry?.outcome == .inserted)
        #expect(entry?.summary == "Checked keyscribe blue")
        #expect(fact(entry, "Command") == "Check status")
        #expect(fact(entry, "Conversation")?.hasPrefix("keyscribe blue") == true)
        #expect(!(entry?.facts ?? []).contains { $0.value.contains("ready") })
    }

    @Test func askingTheNamedConversationWhatItIsWaitingForReportsTheApproval() async {
        let rig = await rig(
            "Ask the keyscribe what it is waiting for from me.", current: "claude:s2", firstStatus: "waiting", firstWaitingFor: "permission prompt")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(showsAnswer(rig, "keyscribe is waiting for approval. Say \u{201C}open keyscribe\u{201D} to see it."))
        #expect(rig.hub.current == "claude:s2")
    }

    @Test func thePendingQuestionIsReadAsAsked() async {
        let rig = await rig("What does keyscribe need from me?", current: "claude:s1", firstStatus: "waiting", firstWaitingFor: "custom")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "select", title: "Keep the schema or add a migration?")))
        let (output, speaker) = speaking(rig)
        await take(rig)
        #expect(showsAnswer(rig, "keyscribe asks: Keep the schema or add a migration? Say \u{201C}open keyscribe\u{201D} to see it."))
        #expect(speaker.spoken == ["keyscribe asks: Keep the schema or add a migration?"])
        withExtendedLifetime(output) {}
    }

    @Test func aPromptWithoutAQuestionIsDescribedThroughTheChosenService() async {
        let rig = await rig("What is keyscribe waiting for?", current: "claude:s1", firstStatus: "waiting", firstWaitingFor: "custom")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "confirm", tool: "bash", detail: "git push origin main")))
        let (output, _) = speaking(rig, llm: DescribingLLM(), connection: Self.service.id)
        await take(rig)
        #expect(showsAnswer(rig, "keyscribe: Asks whether to allow pushing to main. Say \u{201C}open keyscribe\u{201D} to see it."))
        withExtendedLifetime(output) {}
    }

    @Test func aDescriptionOfAPromptThatWasReplacedMeanwhileIsNeverShown() async {
        let rig = await rig("What is keyscribe waiting for?", current: "claude:s1", firstStatus: "waiting", firstWaitingFor: "custom")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "confirm", tool: "bash", detail: "git push origin main")))
        let llm = DescribingLLM()
        let hub = rig.hub
        llm.during = { await MainActor.run { hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "confirm", tool: "bash", detail: "rm -rf build"))) } }
        let (output, _) = speaking(rig, llm: llm, connection: Self.service.id)
        await take(rig)
        #expect(showsAnswer(rig, "keyscribe has a dialog open. Say \u{201C}open keyscribe\u{201D} to see it."))
        #expect(!rig.hud.states.contains { $0.primaryText?.contains("pushing") == true })
        withExtendedLifetime(output) {}
    }

    @Test func aWaitingQuestionWithoutANameChecksTheTakesRecipient() async {
        let rig = await rig("What are you waiting for?", current: "claude:s1", firstStatus: "busy")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(showsAnswer(rig, "keyscribe is working. No request for your input is currently reported."))
        #expect(fact(await lastHistoryEntry(rig), "Chosen by") == "The current conversation")
    }

    @Test func aWaitingQuestionWithNoRecipientAsksForAName() async {
        let rig = await rig("What are you waiting for?")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error("Say the name of the conversation to check on", _, _) = $0 { true } else { false }
        })
    }

    @Test func turningCodingAgentsOffWhileFindingTheConversationInFrontAnswersNothing() async {
        let slow = SlowFront()
        let rig = await inFront("What are you waiting for?", glance: slow, frontGrace: .seconds(30))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.codingAgentId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        try? await Task.sleep(for: .milliseconds(150))
        var settings = rig.controller.settings
        settings.features.setEnabled(false, for: .codingAgents)
        rig.controller.updateSettings(settings)
        slow.release.fire()
        await rig.controller.dictationTask?.value
        #expect(!rig.hud.states.contains { if case .advisory = $0 { true } else { false } })
        #expect(!rig.controller.isBusy)
    }

    @Test func aMessageRetryNamesAConversationThatCanReceiveItRatherThanTheHighlightedOneWithoutItsConnector() async {
        let rig = await rig("Tell frontend to run the tests.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.unreachable = ["claude:s1"]
        rig.hub.refresh()
        await take(rig)
        #expect(rig.hud.states.contains {
            if case .error(let message, .openCodingAgents?, _) = $0 {
                message == "Not sent: no conversation named \u{201C}frontend\u{201D}. Try \u{201C}tell keyscribe blue, \u{2026}\u{201D}"
            } else { false }
        })
    }

    @Test func noConversationThatCanReceiveAMessageLeavesOnlyTheProblemAndTheSettingsButton() async {
        let rig = await rig("Tell frontend to run the tests.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.live = false
        rig.hub.refresh()
        await take(rig)
        #expect(rig.hud.states.contains {
            if case .error("Not sent: no conversation named \u{201C}frontend\u{201D}", .openCodingAgents?, _) = $0 { true } else { false }
        })
    }

    @Test func anOpenRetryStillNamesAConversationWithoutItsConnector() async {
        let rig = await rig("Open frontend.", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.live = false
        rig.hub.refresh()
        await take(rig)
        #expect(rig.hud.states.contains {
            if case .error("No conversation named \u{201C}frontend\u{201D}. Try \u{201C}open keyscribe\u{201D}", .openCodingAgents?, _) = $0 { true } else { false }
        })
    }

    @Test func aDisconnectedConversationIsNeverOfferedAsTheRetry() async {
        let rig = await rig("Tell frontend to run the tests.")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.disconnect("claude:s1")
        await take(rig)
        #expect(rig.hud.states.contains {
            if case .error(let message, _, _) = $0 {
                message == "Not sent: no conversation named \u{201C}frontend\u{201D}. Try \u{201C}tell keyscribe blue, \u{2026}\u{201D}"
            } else { false }
        })
    }

    @Test func aDisconnectedConversationIsReportedAsDisconnectedNotEnded() async {
        let rig = await rig("What is keyscribe blue waiting for?", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.disconnect("claude:s2")
        await take(rig)
        #expect(rig.texts.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error("keyscribe blue is disconnected", .openCodingAgents?, _) = $0 { true } else { false }
        })
    }

    @Test func aWaitingQuestionWithMoreWordsAboutANamedConversationIsHeld() async {
        let rig = await rig("What does keyscribe blue need from me to continue?", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error("Nothing was sent. Say \u{201C}what is keyscribe blue waiting for?\u{201D} to check on it, or start with \u{201C}tell keyscribe blue\u{201D} to send a message", _, _) = $0 { true } else { false }
        })
    }

    @Test func theBeforeANameWithoutABreakIsHeldRatherThanSentToTheCurrentConversation() async {
        let rig = await rig("Tell the keyscribe blue run the tests", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error(let message, _, _) = $0 { message.hasPrefix("Not sent: did you mean \u{201C}keyscribe blue\u{201D}?") } else { false }
        })
        let row = await self.rig("Tell the session two run the tests", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: row.supportDir) }
        await take(row)
        #expect(row.sent.isEmpty)
        let sameRecipient = await self.rig("Tell the keyscribe blue run the tests", current: "claude:s2")
        defer { try? FileManager.default.removeItem(at: sameRecipient.supportDir) }
        await take(sameRecipient)
        #expect(sameRecipient.texts == ["Tell the keyscribe blue run the tests"])
    }

    @Test func aSpokenAnswerIsDroppedWhenTheConnectorGoesAwayBeforeItPlays() async {
        let rig = await rig("What is keyscribe waiting for?", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let silencer = SpeechSilencer()
        let speaker = Speaker()
        let output = SpokenResultOutput(
            client: HTTPLLMClient(), permits: { _ in true }, speech: speaker, silencer: silencer,
            settings: { SpokenResultSettings(enabled: true) }, connection: { _ in nil })
        rig.controller.spokenUpdates = output
        silencer.recordingStarted()
        await take(rig)
        #expect(showsAnswer(rig, "keyscribe is ready for another message."))
        rig.transport.live = false
        rig.hub.refresh()
        silencer.recordingEnded()
        for _ in 0..<200 { await Task.yield() }
        #expect(speaker.spoken.isEmpty)
        withExtendedLifetime(output) {}
    }

    @Test func aStateCarriedFromAnEarlierCheckIsReportedAsLastSeen() async {
        let running = Int(ProcessInfo.processInfo.processIdentifier)
        let rig = await rig(
            "What is keyscribe waiting for?", current: "claude:s2", firstStatus: "waiting", firstWaitingFor: "permission prompt", firstPid: running)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.registry.unreadable = true
        await rig.hub.rescan()
        await take(rig)
        #expect(showsAnswer(rig, "keyscribe was last seen waiting for approval. I couldn\u{2019}t check its current status."))
        let who = await self.rig("Who needs me?", current: "claude:s2", firstStatus: "waiting", firstWaitingFor: "permission prompt", firstPid: running)
        defer { try? FileManager.default.removeItem(at: who.supportDir) }
        who.registry.unreadable = true
        await who.hub.rescan()
        await take(who)
        #expect(showsAnswer(who, "No confirmed requests for your input. I couldn\u{2019}t check every conversation."))
    }

    @Test func whoNeedsMeIsNotSpokenOnceItCouldNoLongerCheckEveryConversation() async {
        let rig = await rig("Who needs me?", current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let silencer = SpeechSilencer()
        let speaker = Speaker()
        let output = SpokenResultOutput(
            client: HTTPLLMClient(), permits: { _ in true }, speech: speaker, silencer: silencer,
            settings: { SpokenResultSettings(enabled: true) }, connection: { _ in nil })
        rig.controller.spokenUpdates = output
        silencer.recordingStarted()
        await take(rig)
        #expect(showsAnswer(rig, "No conversation needs you."))
        rig.registry.unreadable = true
        await rig.hub.rescan()
        silencer.recordingEnded()
        for _ in 0..<200 { await Task.yield() }
        #expect(speaker.spoken.isEmpty)
        withExtendedLifetime(output) {}
    }

    @Test func whoNeedsMeCountsAWaitingConversationWithoutItsConnector() async {
        let rig = await rig("Who needs me?", current: "claude:s2", firstStatus: "waiting", firstWaitingFor: "permission prompt")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.live = false
        rig.hub.refresh()
        await take(rig)
        #expect(showsAnswer(rig, "One conversation needs you: keyscribe. I couldn\u{2019}t check every conversation."))
    }

    @Test func whoNeedsMeNamesTheConversationsWaitingForInput() async {
        let rig = await rig("Who needs me?", current: "claude:s2", firstStatus: "waiting", firstWaitingFor: "permission prompt")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(showsAnswer(rig, "One conversation needs you: keyscribe."))
        #expect(rig.hub.current == "claude:s2")
        #expect(fact(await lastHistoryEntry(rig), "Command") == "Who needs me")
    }

    @Test(arguments: [
        ("Tell keyscribe what it is waiting for", "what it is waiting for"),
        ("What is the build waiting for?", "What is the build waiting for?"),
        ("What is frontend waiting for?", "What is frontend waiting for?"),
        ("Ask keyscribe what it needs, then review the changes.", "what it needs, then review the changes."),
    ])
    func aQuestionThatIsNotAStatusCheckIsSentAsAMessage(text: String, sent: String) async {
        let rig = await rig(text, current: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.texts == [sent])
    }
}
