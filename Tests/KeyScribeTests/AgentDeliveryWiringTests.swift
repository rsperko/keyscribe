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
        func isLive(session: String) -> Bool { live }
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
        namesFile: String? = nil, focus: AgentTerminalFocusing? = nil, firstStatus: String = "idle",
        historyEnabled: Bool = true, receiptTimeout: Duration = .seconds(8),
        front: FrontWindow = FrontWindow(TargetSnapshot(bundleId: "test.bundle")), sessionInFront: Front = Front(),
        glance: (any AgentFronting)? = nil, engine: (any SpeechEngine)? = nil, frontGrace: Duration = .seconds(1),
        maxRecordingSeconds: Double = RecordingLimit.backstopSeconds
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
        let entries: @Sendable () -> [ClaudeRegistryEntry] = {
            [
                ClaudeRegistryEntry(pid: 10, sessionId: "s1", cwd: "/src/keyscribe", name: nil, status: registry.firstStatus, waitingFor: nil),
                ClaudeRegistryEntry(pid: 11, sessionId: "s2", cwd: "/src/keyscribe", name: nil, status: "idle", waitingFor: nil),
            ]
        }
        let agentsDir = supportDir.appendingPathComponent("agents", isDirectory: true)
        if let namesFile {
            try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            try? Data(namesFile.utf8).write(to: agentsDir.appendingPathComponent(AgentNameStore.fileName))
        }
        let hub = AgentHub(transport: transport, scan: { entries() }, names: AgentNameStore(directory: agentsDir), focus: focus,
                           front: sessionInFront, glance: glance, receiptTimeout: receiptTimeout, scanDeadline: .seconds(30))
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
        #expect(rig.hud.states.contains { if case .error(let message, _, _) = $0 { message == "No conversation named \u{201C}two\u{201D}" } else { false } })
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
        runner.outcome = .done(summary: "docs", command: "Replays the last spoken update.")
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
        ("Open frontend.", "No conversation named \u{201C}frontend\u{201D}"),
        ("Go to key scrub", "\u{201C}key scrub\u{201D} sounded like \u{201C}keyscribe\u{201D}"),
        ("Go to session keyscribe review", "No conversation named \u{201C}keyscribe review\u{201D}"),
    ])
    func anOpenVerbWithAFewWordsNamingNothingIsHeldAndNeverSent(text: String, line: String) async {
        let focus = Focus()
        let rig = await rig(text, current: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(focus.sessions.isEmpty)
        #expect(rig.hub.current == "claude:s1")
        #expect(rig.hud.states.contains { if case .error(let message, _, _) = $0 { message == line } else { false } })
        #expect(entry?.summary == line)
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
}
