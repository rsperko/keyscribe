import AppKit
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
        var refusal: String?
        var refusalWhenMerging: String?
        var onSubmit: (() -> Void)?
        var onMerge: (() -> Void)?
        var promptBox: String?
        var onCheck: (() -> Void)?
        weak var hub: AgentHub?
        func rehello(session: String) {}
        func silence(agents: Set<String>) {}
        func enqueue(_ command: AgentCommand, for session: String, instance: String?) {
            sent.append((command, session))
            if case .submit = command { onSubmit?() }
            if case .check(let check, _, let request, _) = command {
                onCheck?()
                guard let promptBox else { return }
                Task { @MainActor [weak hub] in
                    hub?.handle(.checked(request: request, check: check, report: .init(state: .refused, reason: "filled", promptBox: promptBox)))
                }
                return
            }
            if case .submit(_, _, _, _, _, _, _, true) = command, let refusalWhenMerging {
                onMerge?()
                Task { @MainActor [weak hub] in hub?.handle(.refused(request: command.id, reason: refusalWhenMerging)) }
                return
            }
            if let refusal, case .submit = command {
                Task { @MainActor [weak hub] in hub?.handle(.refused(request: command.id, reason: refusal)) }
                return
            }
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
        func isLive(instance: String) -> Bool { live }
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
        private(set) var asked = 0
        init(_ id: String? = nil, window: String? = "cg:3") {
            answer = id.map { FrontSession(id: $0, app: FrontApp(bundle: "com.mitchellh.ghostty", pid: 9, name: "Ghostty", window: window)) }
        }
        func shown(among agents: [AgentFrontCandidate], asking: @escaping @MainActor @Sendable (String) -> Void) async -> FrontSession? {
            asked += 1
            return answer
        }
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

    @MainActor private final class Inputs {
        var latest: UInt64 = 0
        var onInput: ((UInt64) -> Void)?
        func note(at time: UInt64) {
            latest = max(latest, time)
            onInput?(time)
        }
        func typeNow() { note(at: DispatchTime.now().uptimeNanoseconds) }
    }

    private final class Returns: @unchecked Sendable {
        var pressed: [Mode.Submit] = []
        var typedBy: String?
        weak var hub: AgentHub?
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
        var firstGone = false
    }

    @MainActor private final class Unconnected: AgentDiscovery {
        let kind = AgentKind.pi
        let candidates: [AgentCandidate]
        init(candidates: [AgentCandidate]) { self.candidates = candidates }
        func scan(rereadingTitles: Bool) async -> AgentScan { .found([], AgentScanExtras(candidates: candidates)) }
        func stillRunning(_ remembered: RememberedName) -> Bool { false }
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
        let returns: Returns
        let inputs: Inputs

        var sent: [(AgentCommand, String)] { transport.sent }
        var texts: [String] {
            sent.compactMap { if case .submit(_, _, let text, _, _, _, _, _) = $0.0 { text } else { nil } }
        }
    }

    private func agentMode() -> Mode { Mode.agentMode }

    private func rig(
        _ transcript: String, modes: [Mode]? = nil, focused: String? = nil, enabled: Bool = true,
        connection: Connection? = nil, llm: (any LLMClient)? = nil, voiceCommands: VoiceCommandRunning? = nil,
        namesFile: String? = nil, focus: AgentTerminalFocusing? = nil, firstStatus: String = "idle", firstWaitingFor: String? = nil,
        firstPid: Int = 10,
        historyEnabled: Bool = true, receiptTimeout: Duration = .seconds(8),
        front: FrontWindow? = nil, sessionInFront: Front = Front(),
        glance: (any AgentFronting)? = nil, engine: (any SpeechEngine)? = nil, frontGrace: Duration = .seconds(1),
        maxRecordingSeconds: Double = RecordingLimit.backstopSeconds, places: (any AgentPlaceReading)? = nil,
        clipboard: String? = nil, pasteboard: ((NSPasteboard) -> Void)? = nil, unconnected: [AgentCandidate] = [],
        hosts: [AgentHostIntegration] = []
    ) async -> Rig {
        let glance = glance ?? focused.map { Front($0) }
        let front = front ?? FrontWindow(glance == nil ? TargetSnapshot(bundleId: "test.bundle") : Self.terminal)
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-agent-\(UUID().uuidString)", isDirectory: true)
        let modesDir = supportDir.appendingPathComponent("modes", isDirectory: true)
        try? FileManager.default.createDirectory(at: modesDir, withIntermediateDirectories: true)
        for mode in modes ?? [agentMode()] { try? ModeStore.write(mode, to: modesDir) }
        if let connection { try? ConnectionStore.write(ConnectionSet(connections: [connection]), to: supportDir) }

        var settings = Settings.defaults
        settings.stt = .init(engine: "fixed", eviction: .frugal)
        settings.duringDictation = .init(otherAudio: .unchanged, keepDisplayAwake: false, sounds: false)
        settings.features.setEnabled(enabled, for: .agents)
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
            ].filter { !registry.firstGone || $0.sessionId != "s1" }
        }
        let agentsDir = supportDir.appendingPathComponent("agents", isDirectory: true)
        if let namesFile {
            try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            try? Data(namesFile.utf8).write(to: agentsDir.appendingPathComponent(AgentNameStore.fileName))
        }
        let hub = AgentHub(
            transport: transport, discovery: [ClaudeDiscovery(scan: { entries() }), Unconnected(candidates: unconnected)],
            names: AgentNameStore(directory: agentsDir), focus: focus, front: sessionInFront, glance: glance,
            receiptTimeout: receiptTimeout, scanDeadline: .seconds(30), places: places,
            hosts: hosts, hostAllowed: { _ in true })
        transport.hub = hub
        await hub.rescan()

        let captured = Captured()
        let returns = Returns()
        returns.hub = hub
        let hud = HUDSpy()
        let history = HistoryStore(supportDir: supportDir)
        let provider = try! SpeechEngineProvider(engines: [engine ?? FixedEngine(text: transcript)], activeId: "fixed")
        let config = ConfigCache(supportDir: supportDir)
        config.agentsEnabled = true
        let audio = FakeAudio(url: supportDir.appendingPathComponent("capture.wav"))
        let controller = DictationController(
            settings: settings, provider: provider, config: config,
            history: history, hud: hud, permits: { _ in true },
            audio: audio,
            insert: { _, _, _, text, _ in captured.insertedText = text; return true },
            submitKey: { key in
                returns.pressed.append(key)
                if let session = returns.typedBy { await MainActor.run { returns.hub?.handle(.typed(session: session)) } }
            },
            clipboard: { clipboard },
            agentClipboard: AgentClipboard(pasteboard: Self.pasteboard(clipboard, pasteboard), folder: supportDir.appendingPathComponent("clipboard"), restorePending: {}),
            snapshot: { front.snapshot },
            micStatus: { .granted },
            accessibilityGranted: { true },
            llmClient: llm ?? HTTPLLMClient(),
            voiceCommands: voiceCommands,
            maxRecordingSeconds: maxRecordingSeconds)
        controller.agents = hub
        controller.frontReadingGrace = frontGrace
        let inputs = Inputs()
        controller.inputAfter = { inputs.latest > $0 }
        inputs.onInput = { [weak controller] in controller?.noteUserInput(at: $0) }
        hub.onNotice = { [weak controller] in controller?.showAgentNotice($0, request: $1, conversation: $2) }
        hub.onForget = { [weak controller] in controller?.forgetAgentReceipt(request: $0) }
        hub.onLeftInPromptBox = { [weak controller] in controller?.sendLeftInPromptBox(request: $0, conversation: $1, handle: $2) }
        hub.onDelivery = { [weak controller] in controller?.recordAgentDelivery($1, request: $0) }
        controller.agentNoticeDelayOverride = .milliseconds(10)
        return Rig(
            controller: controller, hub: hub, transport: transport, hud: hud, captured: captured, history: history,
            supportDir: supportDir, registry: registry, audio: audio, returns: returns, inputs: inputs)
    }

    private static func pasteboard(_ text: String?, _ fill: ((NSPasteboard) -> Void)?) -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        if let text { pasteboard.setString(text, forType: .string) }
        fill?(pasteboard)
        return pasteboard
    }

    private static func png() throws -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test(arguments: [(["images"], "Sent to keyscribe with 1 image"), ([String](), "Sent to keyscribe with the path to 1 image")])
    func theHUDSaysWhetherTheImageWentWithTheMessage(_ features: [String], _ summary: String) async throws {
        let png = try Self.png()
        let rig = await rig("Look at insert clipboard contents", focused: "claude:s1", pasteboard: { $0.setData(png, forType: .png) })
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, features: features)))
        await take(rig)
        guard case .submit(let request, _, _, _, _, _, _, _) = rig.sent.last?.0 else { Issue.record("nothing handed off"); return }
        rig.hub.handle(.submitted(request: request, turn: ""))
        await rig.controller.dictationTask?.value
        #expect(rig.hud.states.contains(.commandDone(summary: summary, detail: "Agent")))
    }

    @Test func anEmptyClipboardSaysItsWordsWereSentAsSaid() async throws {
        let rig = await rig("Fix insert clipboard contents", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        guard case .submit(let request, _, let text, _, _, _, _, _) = rig.sent.last?.0 else { Issue.record("nothing handed off"); return }
        #expect(text.lowercased().contains("insert clipboard contents"))
        rig.hub.handle(.submitted(request: request, turn: ""))
        await rig.controller.dictationTask?.value
        #expect(rig.hud.states.contains(.advisory(
            message: "Sent to keyscribe, but the clipboard had nothing to insert, so \u{201C}insert clipboard contents\u{201D} went as words")))
    }

    @Test func aCopiedImageReachesTheAgentAsAFileItCanOpen() async throws {
        let png = try Self.png()
        let rig = await rig("What is wrong here? Insert clipboard contents.", focused: "claude:s1", pasteboard: { $0.setData(png, forType: .png) })
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 0, features: ["images"])))
        await take(rig)
        let folder = rig.supportDir.appendingPathComponent("clipboard")
        let saved = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(saved.count == 1)
        let path = folder.appendingPathComponent(try #require(saved.first)).path
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == png)
        guard case .submit(_, _, let text, _, _, let images, _, _) = rig.sent.last?.0 else { Issue.record("nothing handed off"); return }
        #expect(text == "What is wrong here \(path)?")
        #expect(images == [path])
    }

    @Test func copiedTextStillReachesTheAgentAsText() async throws {
        let rig = await rig("Use insert clipboard as code", focused: "claude:s1", clipboard: "x = 1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.texts.first?.contains("```\nx = 1\n```") == true)
    }

    private func take(_ rig: Rig, mode: String = Mode.agentModeId, readingTheFront: Bool = false) async {
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

    private func stoppedRig(
        _ inFront: String?, typed: Bool = true, refusal: String? = "filled", features: [String] = ["fill"], front: Front? = nil
    ) async -> Rig {
        let rig = await rig("Tell keyscribe, run the tests.", glance: front ?? Front(inFront))
        rig.hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 10, features: features)))
        rig.transport.refusal = refusal
        rig.returns.typedBy = typed ? "claude:s1" : nil
        rig.controller.promptBoxConfirmation = .milliseconds(200)
        return rig
    }

    private func settledEntry(_ rig: Rig) async -> HistoryEntry? {
        for _ in 0..<200 where rig.history.entries().isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        return rig.history.entries().first
    }

    @Test func aMessageLeftInThePromptBoxOfTheConversationInFrontIsSentWithReturn() async {
        let rig = await stoppedRig("claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.returns.pressed == [.return])
        let entry = await settledEntry(rig)
        #expect(entry?.outcome == .inserted)
        #expect(entry?.summary == "Sent to keyscribe")
    }

    @Test func aMessageLeftInThePromptBoxOfAConversationNotInFrontWaitsThereForTheUser() async {
        let rig = await stoppedRig("claude:s2")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.returns.pressed.isEmpty)
        #expect(rig.hud.states.last == AgentOutput.receiptState(.kept("keyscribe", reason: .inPromptBox(.afterStop)), mode: "Agent", heard: ""))
    }

    @Test func aMessageLeftInThePromptBoxWithNoConversationKnownInFrontWaitsThereForTheUser() async {
        let rig = await stoppedRig(nil)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.returns.pressed.isEmpty)
    }

    @Test func aReturnTheConversationNeverSeesIsReportedAsUncertain() async {
        let rig = await stoppedRig("claude:s1", typed: false)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.returns.pressed == [.return])
        #expect((await settledEntry(rig))?.outcome == .failed)
        #expect(rig.hud.states.last == AgentOutput.receiptState(.uncertain("keyscribe"), mode: "Agent", heard: ""))
    }

    @Test(arguments: ["stopped", "draft", "typedSince", "busy elsewhere"])
    func noOtherRefusalPressesReturn(refusal: String) async {
        let rig = await stoppedRig("claude:s1", refusal: refusal)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.returns.pressed.isEmpty)
    }

    private func merged(_ rig: Rig) -> [Bool] {
        rig.sent.compactMap { if case .submit(_, _, _, _, _, _, _, let merge) = $0.0 { merge } else { nil } }
    }

    @Test func aDictationRefusedForTypedTextInTheConversationInFrontIsJoinedToItAndSentWithReturn() async {
        let rig = await stoppedRig("claude:s1", refusal: "draft", features: ["merge"])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.refusalWhenMerging = "joined"
        await take(rig)
        #expect(merged(rig) == [false, true])
        #expect(rig.returns.pressed == [.return])
        let entry = await settledEntry(rig)
        #expect(entry?.outcome == .inserted)
        #expect(entry?.summary == "Sent to keyscribe with the text in its prompt box")
        #expect(entry?.facts?.first { $0.label == "Delivery" }?.value.contains("sent with the text already in its prompt box") == true)
    }

    @Test func aDictationToAnIdleConversationWithAnEmptyBoxNeverChecksWhatIsInFront() async {
        let plain = Front("claude:s1")
        let merging = Front("claude:s1")
        let without = await stoppedRig(nil, refusal: nil, features: [], front: plain)
        let with = await stoppedRig(nil, refusal: nil, features: ["merge"], front: merging)
        defer {
            try? FileManager.default.removeItem(at: without.supportDir)
            try? FileManager.default.removeItem(at: with.supportDir)
        }
        await take(without)
        await take(with)
        #expect(merged(with) == [false])
        #expect(merging.asked == plain.asked)
        #expect((await settledEntry(with))?.summary == "Sent to keyscribe")
    }

    @Test func aDictationForAConversationNotInFrontNeverJoinsWhatTheUserTyped() async {
        let rig = await stoppedRig("claude:s2", refusal: "draft", features: ["merge"])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(merged(rig) == [false])
        #expect(rig.returns.pressed.isEmpty)
        #expect(rig.hud.states.last == AgentOutput.receiptState(.kept("keyscribe", reason: .composing), mode: "Agent", heard: ""))
    }

    @Test func aConnectorThatNeverSaidItJoinsDraftsIsNeverAskedTo() async {
        let rig = await stoppedRig("claude:s1", refusal: "draft", features: ["fill"])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(merged(rig) == [false])
        #expect(rig.returns.pressed.isEmpty)
    }

    @Test func aJoinedDictationWhoseConversationLeavesTheFrontWaitsInItsPromptBox() async {
        let front = Front("claude:s1")
        let rig = await stoppedRig(nil, refusal: "draft", features: ["merge"], front: front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.refusalWhenMerging = "joined"
        rig.transport.onMerge = { front.answer = nil }
        await take(rig)
        #expect(merged(rig) == [false, true])
        #expect(rig.returns.pressed.isEmpty)
        #expect(rig.hud.states.last == AgentOutput.receiptState(.kept("keyscribe", reason: .inPromptBox(.joinedDraft)), mode: "Agent", heard: ""))
    }

    @Test func aDictationJoinedToADraftWhileTheConversationWorksIsSentWithReturnAsTyped() async {
        let rig = await workingRig(Front("claude:s1"), features: ["readiness", "fill", "box", "merge"])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.refusal = "joinedMidTurn"
        await take(rig)
        #expect(boxed(rig) == [true])
        #expect(merged(rig) == [true])
        #expect(rig.returns.pressed == [.return])
        #expect((await settledEntry(rig))?.summary == "Sent to keyscribe with the text in its prompt box")
    }

    @Test func aConnectorThatNeverSaidItFillsThePromptBoxIsNotTrustedToHaveFilledIt() async {
        let rig = await stoppedRig("claude:s1", features: ["focus"])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.returns.pressed.isEmpty)
        #expect((await settledEntry(rig))?.outcome == .failed)
    }

    private func workingRig(
        _ front: Front, said: String = "Use the other file.", features: [String] = ["readiness", "fill", "box"]
    ) async -> Rig {
        let rig = await rig(said, firstStatus: "busy", glance: front)
        rig.hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 10,
                                    features: features, idle: false, gap: false)))
        rig.transport.refusal = "filled"
        rig.transport.promptBox = "ready"
        rig.controller.frontApp = { front.answer?.app }
        rig.returns.typedBy = "claude:s1"
        rig.controller.promptBoxConfirmation = .milliseconds(200)
        return rig
    }

    private func boxed(_ rig: Rig) -> [Bool] {
        rig.sent.compactMap { if case .submit(_, _, _, _, _, _, let box, _) = $0.0 { box } else { nil } }
    }

    @Test func aDictationForTheWorkingConversationInFrontIsEnteredInItsPromptBoxAsTyped() async {
        let rig = await workingRig(Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(boxed(rig) == [true])
        #expect(rig.returns.pressed == [.return])
        let entry = await settledEntry(rig)
        #expect(entry?.outcome == .inserted)
        #expect(entry?.summary == "Sent to keyscribe")
    }

    @Test func aDictationEnteredInThePromptBoxOfAConversationNoLongerInFrontWaitsThereForTheUser() async {
        let front = Front("claude:s1")
        let rig = await workingRig(front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.onSubmit = { front.answer = nil }
        await take(rig)
        #expect(boxed(rig) == [true])
        #expect(rig.returns.pressed.isEmpty)
        #expect(rig.hud.states.last == AgentOutput.receiptState(.kept("keyscribe", reason: .inPromptBox(.awaitingReturn)), mode: "Agent", heard: ""))
    }

    @Test(arguments: ["asking", "changed", nil] as [String?])
    func returnIsNeverPressedUnlessTheConnectorSaysTheBoxIsReady(_ promptBox: String?) async {
        let rig = await workingRig(Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.promptBox = promptBox
        rig.hub.promptBoxCheckWait = .milliseconds(100)
        await take(rig)
        #expect(boxed(rig) == [true])
        #expect(rig.returns.pressed.isEmpty)
        #expect(rig.hud.states.last == AgentOutput.receiptState(.kept("keyscribe", reason: .inPromptBox(.awaitingReturn)), mode: "Agent", heard: ""))
    }

    @Test func returnIsNeverPressedWhenFocusMovesWhileTheBoxIsChecked() async {
        let front = Front("claude:s1")
        let rig = await workingRig(front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        var focused = front.answer?.app
        rig.controller.frontApp = { focused }
        rig.transport.onCheck = { focused = FrontApp(bundle: "com.apple.Safari", pid: 11, name: "Safari", window: "cg:7") }
        await take(rig)
        #expect(boxed(rig) == [true])
        #expect(rig.returns.pressed.isEmpty)
        #expect(rig.hud.states.last == AgentOutput.receiptState(.kept("keyscribe", reason: .inPromptBox(.awaitingReturn)), mode: "Agent", heard: ""))
    }

    @Test func returnIsNeverPressedWhenAnotherPaneOfTheSameWindowComesToFrontWhileTheBoxIsChecked() async {
        let front = Front("claude:s1")
        let rig = await workingRig(front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let app = front.answer?.app
        rig.controller.frontApp = { app }
        rig.transport.onCheck = { front.answer = app.map { FrontSession(id: "claude:s2", app: $0) } }
        await take(rig)
        #expect(boxed(rig) == [true])
        #expect(rig.returns.pressed.isEmpty)
        #expect(rig.hud.states.last == AgentOutput.receiptState(.kept("keyscribe", reason: .inPromptBox(.awaitingReturn)), mode: "Agent", heard: ""))
    }

    @Test func aDictationAddedBesideTextTheUserTypedIsLeftForThemToReview() async {
        let rig = await workingRig(Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.refusal = "added"
        await take(rig)
        #expect(rig.returns.pressed.isEmpty)
        #expect(rig.hud.states.last == AgentOutput.receiptState(.kept("keyscribe", reason: .inPromptBox(.besideText)), mode: "Agent", heard: ""))
    }

    @Test func aMessageInThePromptBoxSaysWhyItWaitsThere() {
        #expect(AgentOutput.receiptState(.kept("docs", reason: .inPromptBox(.awaitingReturn)), mode: "Agent", heard: "")
            == .advisory(message: "Not sent to docs: the message is in its prompt box. Review it there and press Return to send it"))
        #expect(AgentOutput.receiptState(.kept("docs", reason: .inPromptBox(.besideText)), mode: "Agent", heard: "")
            == .advisory(message: "Not sent to docs: the message was added to its prompt box after text already there. Review it there and press Return to send it"))
    }

    @Test func aNewConversationTheHostWouldNotStartSaysWhatTheHostSaid() {
        let alone = AgentReceipt.kept("a new bb conversation", reason: .declined(by: "bb", saying: "Enter a prompt or attach a file.", besideText: false))
        #expect(AgentOutput.receiptState(alone, mode: "Agent", heard: "")
            == .advisory(message: "Not sent to a new bb conversation: bb said \u{201C}Enter a prompt or attach a file.\u{201D} Your words are in its prompt box"))
        let beside = AgentReceipt.kept("a new bb conversation", reason: .declined(by: "bb", saying: "Uploads failed.", besideText: true))
        #expect(AgentOutput.receiptState(beside, mode: "Agent", heard: "")
            == .advisory(message: "Not sent to a new bb conversation: bb said \u{201C}Uploads failed.\u{201D} Your words are in its prompt box, after the text already there"))
    }

    @Test func aDictationTheRunningTurnTookInHasThatTurnsReplyHeardForIt() async {
        let rig = await workingRig(Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        var origins: [String?] = []
        rig.hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        await take(rig)
        rig.hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("Use the other file.")))
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Used the other file."))
        #expect(origins == [submittedRequest(rig)])
    }

    @Test func aDictationTheRunningTurnEndedWithoutHasOnlyItsOwnTurnsReplyHeardForIt() async {
        let rig = await workingRig(Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        var heard: [(String, String?)] = []
        rig.hub.onResult = { _, _, answer, _, origin, _ in heard.append((answer, origin)) }
        await take(rig)
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Finished the earlier work."))
        rig.hub.handle(.turnStarted(session: "claude:s1", turn: "t2", prompt: AgentPromptDigest.of("Use the other file.")))
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Used the other file."))
        #expect(heard.filter { $0.1 == submittedRequest(rig) }.map(\.0) == ["Used the other file."])
    }

    @Test func aDictationNeverClaimsATurnThatDidNotTakeItIn() async {
        let rig = await workingRig(Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.handle(.turnStarted(session: "claude:s1", turn: "t1"))
        var origins: [String?] = []
        rig.hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        await take(rig)
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Finished the earlier work."))
        rig.hub.handle(.typed(session: "claude:s1"))
        rig.hub.handle(.turnStarted(session: "claude:s1", turn: "t2", prompt: AgentPromptDigest.of("Something else.")))
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Something else."))
        #expect(!origins.contains(submittedRequest(rig)))
    }

    @Test func aDictationForAWorkingConversationNotInFrontWaitsForItsTurn() async {
        let rig = await workingRig(Front("claude:s2"), said: "Tell keyscribe, use the other file.")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(boxed(rig).isEmpty)
        #expect(rig.returns.pressed.isEmpty)
        #expect(rig.hud.states.last == AgentOutput.receiptState(.queued("keyscribe"), mode: "Agent", heard: ""))
    }

    @Test func aSubmissionThatGoesThroughNeverPressesReturn() async {
        let rig = await rig("Run the tests.", focused: "claude:s1", glance: Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.returns.pressed.isEmpty)
        #expect(rig.texts == ["Run the tests."])
    }

    @Test func aHostsRefusalShowsTheHostsReason() {
        #expect(AgentOutput.receiptState(.notSent("docs", reason: .hostRefused("Work bb isn\u{2019}t open.")), mode: "Agent", heard: "")
            == .error(message: "docs didn\u{2019}t take the message: Work bb isn\u{2019}t open. Nothing sent.", action: nil, heard: HeardExcerpt(heard: "")))
        #expect(AgentOutput.spokenRefusal(.notSent("docs", reason: .hostRefused("Work bb isn\u{2019}t open.")))
            == "docs didn\u{2019}t take that: Work bb isn\u{2019}t open")
    }

    @Test func aHostsReasonKeepsTheCaseOfTheCopyNameItStartsWith() {
        #expect(AgentOutput.receiptState(.notSent("docs", reason: .hostRefused("bb (Work) isn\u{2019}t open.")), mode: "Agent", heard: "")
            == .error(message: "docs didn\u{2019}t take the message: bb (Work) isn\u{2019}t open. Nothing sent.", action: nil, heard: HeardExcerpt(heard: "")))
        #expect(AgentOutput.receiptState(.notSent("docs", reason: .hostRefused("bb no longer lists this thread")), mode: "Agent", heard: "")
            == .error(message: "docs didn\u{2019}t take the message: bb no longer lists this thread. Nothing sent.", action: nil, heard: HeardExcerpt(heard: "")))
    }

    @Test func aStoppedConversationSaysWhatHappenedAndHowToGetPastIt() {
        #expect(AgentOutput.receiptState(.notSent("docs", reason: .stopped), mode: "Agent", heard: "")
            == .error(message: "docs\u{2019}s last turn was interrupted, so it takes only a message you type. Nothing sent. Type one there, then dictate again.",
                      action: nil, heard: HeardExcerpt(heard: "")))
        #expect(AgentOutput.receiptState(.kept("docs", reason: .inPromptBox(.afterStop)), mode: "Agent", heard: "")
            == .advisory(message: "Not sent to docs: its last turn was interrupted, so the message is waiting in its prompt box. Press Return there to send it"))
    }

    private func submittedRequest(_ rig: Rig) -> String? {
        rig.sent.compactMap { if case .submit(let id, _, _, _, _, _, _, _) = $0.0 { id } else { nil } }.first
    }

    private func heard(_ text: String, connection: String? = nil, origin: String?) -> SpokenResultOutput.Heard {
        .init(conversation: "claude:s1", name: "keyscribe", text: text, connection: connection, origin: origin)
    }

    private func entries(_ rig: Rig, count: Int) async -> [HistoryEntry] {
        for _ in 0..<200 where rig.history.entries().count < count {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        rig.controller.waitForHistoryWrites()
        return rig.history.entries()
    }

    private func replied(_ rig: Rig) async -> HistoryEntry? {
        for _ in 0..<200 where rig.history.entries().first?.spokenReply == nil {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        return rig.history.entries().first
    }

    @Test func aReplyReadAloudIsKeptWithTheTakeThatAskedForIt() async {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        _ = await entries(rig, count: 1)
        rig.controller.recordSpokenReply(heard("keyscribe: The tests pass.", connection: "Local", origin: submittedRequest(rig)))
        let entry = await replied(rig)
        #expect(rig.history.entries().count == 1)
        #expect(entry?.heard == "Run the tests.")
        #expect(entry?.spokenReply?.text == "keyscribe: The tests pass.")
        #expect(entry?.spokenReply?.connection == "Local")
        #expect(entry?.spokenReply?.conversation == "keyscribe")
        #expect(entry?.spokenReply?.answers == nil)
    }

    @Test func aReplyReadAloudKeepsWhatItAnswered() async {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        _ = await entries(rig, count: 1)
        var spoken = heard("keyscribe, answering another agent: The race is fixed.", origin: submittedRequest(rig))
        spoken.cause = .sender(.agent)
        rig.controller.recordSpokenReply(spoken)
        let entry = await replied(rig)
        #expect(entry?.spokenReply?.answers == "agent")
        #expect(entry?.spokenReply?.answersLabel == "Another agent")
    }

    @Test func aReplyReadAloudKeepsItsSpokenAudioWithItsEntryAndSaysWhichVoiceReadIt() async throws {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let attempts = SpokenAttempts()
        rig.controller.spokenAttempts = attempts
        await take(rig)
        _ = await entries(rig, count: 1)
        let attempt = attempts.begin(text: "keyscribe: The tests pass.", voice: "af_heart")
        _ = attempts.begin(text: "a later preview", voice: "af_heart")
        let original = attempts.begin(text: "keyscribe: The tests pass.", voice: "af_heart")
        var spoken = heard("keyscribe: The tests pass.", origin: submittedRequest(rig))
        spoken.attempt = original
        spoken.reader = .macOS
        spoken.reason = "the natural voice made silent audio"
        var recorded: [(String?, String)] = []
        rig.controller.onSpokenReplyRecorded = { recorded.append(($0, $1)) }
        rig.controller.recordSpokenReply(spoken)
        attempts.ended(original)
        let entry = try #require(await replied(rig))
        for _ in 0..<200 where recorded.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(recorded.map(\.0) == [original])
        #expect(recorded.map(\.1) == [entry.id])
        #expect(entry.spokenReply?.voice == "macos")
        #expect(entry.spokenReply?.reason == "the natural voice made silent audio")
        #expect(rig.controller.lastSpokenReplyEntry == entry.id)
        #expect(rig.controller.lastHeardReply?.entry == entry.id)
        #expect(!rig.controller.forgetSpokenReplies(["another"]))
        #expect(rig.controller.forgetSpokenReplies([try #require(entry.id)]))
        #expect(rig.controller.lastSpokenReplyEntry == nil)
        _ = attempts.begin(text: "keyscribe: The tests pass.", voice: "af_heart")
        #expect(attempts.attempt(forEntry: try #require(entry.id))?.id == original)
        #expect(attempts.attempt(attempt) == nil)
        attempts.forget(entries: [try #require(entry.id)])
        #expect(attempts.attempt(original) == nil)
    }

    @Test func aReplyHistoryLeavesOutKeepsNoSpokenAudio() async {
        var excluded = agentMode()
        excluded.excludeFromHistory = true
        let rig = await rig("Run the tests.", modes: [excluded], focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let attempts = SpokenAttempts()
        rig.controller.spokenAttempts = attempts
        var spoken = heard("keyscribe: Done.", origin: nil)
        spoken.attempt = attempts.begin(text: "keyscribe: Done.", voice: "af_heart")
        rig.controller.recordSpokenReply(spoken)
        attempts.ended(spoken.attempt)
        #expect(attempts.attempt(spoken.attempt ?? "") == nil)
        #expect(rig.controller.lastHeardReply?.entry == nil)
        #expect(rig.controller.lastHeardReply?.conversation == spoken.name)
    }

    @Test func aReplyWhoseTakeWasDeletedBeforeItPlayedIsNotOfferedAndKeepsNoAudio() async throws {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let attempts = SpokenAttempts()
        rig.controller.spokenAttempts = attempts
        await take(rig)
        let taken = try #require(await entries(rig, count: 1).first)
        rig.history.delete(taken)
        var recorded = 0
        rig.controller.onSpokenReplyRecorded = { _, _ in recorded += 1 }
        var spoken = heard("keyscribe: The tests pass.", origin: submittedRequest(rig))
        spoken.attempt = attempts.begin(text: "keyscribe: The tests pass.", voice: "af_heart")
        rig.controller.recordSpokenReply(spoken)
        attempts.ended(spoken.attempt)
        #expect(attempts.attempt(spoken.attempt ?? "") != nil)
        for _ in 0..<200 where attempts.attempt(spoken.attempt ?? "") != nil {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        #expect(attempts.attempt(spoken.attempt ?? "") == nil)
        #expect(rig.controller.lastSpokenReplyEntry == nil)
        #expect(recorded == 0)
    }

    @Test func aReplyNotReadBecauseItsConversationWasInFrontSaysSoInItsTake() async {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        _ = await entries(rig, count: 1)
        rig.controller.recordUnreadReply(.inFront(name: "keyscribe"), origin: submittedRequest(rig) ?? "")
        for _ in 0..<200 where (rig.history.entries().first?.steps?.count ?? 0) < 2 {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        let entry = rig.history.entries().first
        #expect(entry?.steps?.map(\.text) == ["Sent to keyscribe", "Not read aloud: keyscribe was in front when it finished"])
        #expect(entry?.summary == "Sent to keyscribe")
        #expect(entry?.outcome == .inserted)
        #expect(entry?.spokenReply == nil)
    }

    @Test func aReplyToATakeHistoryLeftOutIsNotKeptAnywhere() async {
        var excluded = agentMode()
        excluded.excludeFromHistory = true
        let rig = await rig("Run the tests.", modes: [excluded], focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        rig.controller.recordSpokenReply(heard("keyscribe: The tests pass.", origin: submittedRequest(rig)))
        #expect(await entries(rig, count: 1).isEmpty)
    }

    @Test func aReplyNoTakeAskedForIsKeptOnItsOwn() async {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.recordSpokenReply(heard("keyscribe: Done.", origin: nil))
        let kept = await entries(rig, count: 1)
        rig.controller.waitForHistoryWrites()
        #expect(kept.map(\.summary) == ["Reply from keyscribe"])
        #expect(kept.map(\.modeName) == ["Agent"])
        #expect(kept.allSatisfy { $0.heard.isEmpty && $0.result.isEmpty && $0.outcome == .command && $0.id != nil })
        #expect(kept.map(\.spokenReply?.text) == ["keyscribe: Done."])
    }

    @Test(arguments: [true, false])
    func aReplyOnItsOwnFollowsHistoryAndTheAgentModesChoice(historyOn: Bool) async {
        var excluded = agentMode()
        excluded.excludeFromHistory = historyOn
        let rig = await rig("Run the tests.", modes: [excluded], focused: "claude:s1", historyEnabled: historyOn)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.recordSpokenReply(heard("keyscribe: Done.", origin: nil))
        #expect(await entries(rig, count: 1).isEmpty)
    }

    @Test func theTurnAMessageSentFromThePromptBoxStartsIsHeardForItsTake() async {
        let rig = await stoppedRig("claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        var origins: [String?] = []
        rig.hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        await take(rig)
        rig.hub.handle(.turnStarted(session: "claude:s1", turn: "t9"))
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "Renamed."))
        #expect(origins == [submittedRequest(rig)])
    }

    @Test func aPromptBoxReturnTheConversationNeverSeesAwaitsNoTurn() async {
        let rig = await stoppedRig("claude:s1", typed: false)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        var origins: [String?] = []
        rig.hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        await take(rig)
        rig.hub.handle(.typed(session: "claude:s1"))
        rig.hub.handle(.turnStarted(session: "claude:s1", turn: "t9"))
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "typed by hand"))
        #expect(origins.isEmpty)
    }

    @Test func aPromptBoxMessageThatStartsNoTurnLendsItsTakeToNoLaterTypedTurn() async {
        let rig = await stoppedRig("claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        var origins: [String?] = []
        rig.hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        await take(rig)
        #expect(rig.returns.pressed == [.return])
        rig.hub.handle(.typed(session: "claude:s1"))
        rig.hub.handle(.turnStarted(session: "claude:s1", turn: "t9"))
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "typed by hand"))
        #expect(origins.isEmpty)
    }

    @Test func aTurnStartingLongAfterThePromptBoxMessageIsNotItsTakes() async {
        let rig = await stoppedRig("claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.typedTurnWindow = 0.05
        var origins: [String?] = []
        rig.hub.onResult = { _, _, _, _, origin, _ in origins.append(origin) }
        await take(rig)
        try? await Task.sleep(for: .milliseconds(100))
        rig.hub.handle(.turnStarted(session: "claude:s1", turn: "t9"))
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: "something else"))
        #expect(origins.isEmpty)
    }

    @Test func aPaneRenamedJustBeforeRecordingIsReachedByItsNewNameOnceTheReadLandsDuringTheTake() async {
        let reader = AgentPlaceTrackerTests.Reader()
        let rig = await rig("architect, run the tests.", focused: "claude:s2", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        let pane = "/s#pane:p1"
        reader.answers = ["claude:s1": .found(AgentPlace(
            surface: "herdr", labels: [.init(text: "architect", level: .pane, container: pane)], containers: [pane]))]
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["run the tests."])
        #expect(rosters(rig).compactMap { $0?.rows.map(\.name) }.allSatisfy { $0 == ["keyscribe", "keyscribe blue"] })
    }

    private func herdrNamedRig(_ text: String, firstStatus: String = "idle", firstWaitingFor: String? = nil) async -> Rig {
        let reader = AgentPlaceTrackerTests.Reader()
        let rig = await rig(text, focused: "claude:s2", firstStatus: firstStatus, firstWaitingFor: firstWaitingFor, places: reader)
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        let pane = "/s#pane:p1", workspace = "/s#workspace:w9"
        reader.answers = ["claude:s1": .found(AgentPlace(
            surface: "herdr",
            labels: [
                .init(text: "marvin", level: .title, container: pane), .init(text: "cos", level: .agent, container: pane),
                .init(text: "chief", level: .workspace, container: workspace),
            ],
            containers: [pane, workspace]))]
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
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
                message == "\u{201C}chief\u{201D} is the herdr workspace label of \u{201C}marvin\u{201D}. Nothing sent. Try \u{201C}ask marvin, \u{2026}\u{201D}. Your words are kept for Paste last dictation."
            } else { false }
        })
        #expect(await lastHistoryEntry(rig)?.failureReason == "\u{201C}chief\u{201D} is the herdr workspace label of \u{201C}marvin\u{201D}. Nothing sent.")
    }

    @Test(arguments: ["Check on cos.", "Check on marvin."])
    func aStatusCheckReachesTheConversationByEitherName(text: String) async {
        let rig = await herdrNamedRig(text, firstStatus: "waiting", firstWaitingFor: "permission prompt")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        #expect(rig.sent.isEmpty)
        #expect(showsAnswer(rig, "Status for marvin: waiting for approval. Nothing sent. Say \u{201C}open marvin\u{201D} to see it."))
    }

    @Test func aRetryUsesTheNameAPaneTookDuringTheTakeNotTheOneItLeft() async {
        let reader = AgentPlaceTrackerTests.Reader()
        let rig = await rig("Tell frontend to run the tests.", focused: "claude:s1", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        let pane = "/s#pane:p1"
        reader.answers = ["claude:s1": .found(AgentPlace(
            surface: "herdr", labels: [.init(text: "zeta", level: .pane, container: pane)], containers: [pane]))]
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error(let message, _, _) = $0 {
                message == "No conversation named \u{201C}frontend\u{201D}. Nothing sent. Try \u{201C}tell zeta, \u{2026}\u{201D}. Your words are kept for Paste last dictation."
            } else { false }
        })
    }

    final class SlowReader: AgentPlaceReading, @unchecked Sendable {
        private let lock = NSLock()
        private var _answers: [String: AgentPlaceAnswer] = [:]
        private var _delay: TimeInterval = 0
        let release = DispatchSemaphore(value: 0)
        private var _blocking = false
        private var _reads = 0
        var reads: Int { lock.withLock { _reads } }
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
            lock.withLock { _reads += 1 }
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
        let rig = await rig("architect, run the tests.", focused: "claude:s2", places: reader)
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
        let rig = await rig("architect, run the tests.", focused: "claude:s2", places: reader)
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
        let rig = await rig("Run the tests.", focused: "claude:s2", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        #expect(rig.hub.placeTracker?.failingSince["claude:s1"] != nil)
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
    }

    @Test func aTakeAfterAFailedReadOfAPlaceReadBeforeKeepsItsNamesAndGoesToTheCurrentConversation() async {
        let reader = SlowReader()
        reader.answers = architect()
        let rig = await rig("Run the tests.", focused: "claude:s2", places: reader)
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
        let rig = await rig("Tell keyscribe blue to run the tests.", focused: "claude:s1", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        reader.answers = ["claude:s1": .unknown]
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
    }

    @Test func aTakeWaitsBrieflyForALabelReadStillRunningAndReachesTheRenamedPane() async {
        let reader = SlowReader()
        let rig = await rig("architect, run the tests.", focused: "claude:s2", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        rig.controller.placeNamesGrace = .seconds(3)
        reader.answers = architect()
        reader.delay = 0.3
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["run the tests."])
    }

    @Test func whileRecordingTheHUDMarksTheConversationInFrontWithoutMovingIt() async {
        let rig = await rig("Run the tests.", focused: "claude:s2")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        let roster = try? #require(rosters(rig).last ?? nil)
        #expect(roster?.rows.map(\.name) == ["keyscribe", "keyscribe blue"])
        #expect(roster?.targetName == "keyscribe blue")
    }

    @Test func aPressNoAgentModeCanServeReadsNoPlacesAndFreezesNoConversations() async {
        let reader = SlowReader()
        let rig = await rig("hello", modes: [.direct], focused: "claude:s1", places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        let before = reader.reads
        rig.controller.setNextModeOverride(id: Mode.directId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        #expect(!rig.controller.hasFrozenAgentSnapshot)
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        #expect(reader.reads == before)
    }

    @Test func aConnectorThatResumedPollingWithoutAHelloIsReachableAtThePress() async {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.live = false
        rig.hub.refresh()
        #expect(!rig.hub.hasConnectedConversation)
        rig.transport.live = true
        await take(rig)
        #expect(rosters(rig).compactMap { $0 }.first?.rows.first { $0.id == "claude:s1" }?.available == true)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
    }

    @Test func anOrdinaryDictationShowsNoSessionList() async {
        let rig = await rig("hello", modes: [agentMode(), .direct], focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, mode: Mode.directId)
        #expect(!rosters(rig).isEmpty)
        #expect(rosters(rig).allSatisfy { $0 == nil })
    }

    @Test func aSpokenNameSendsTheRestToThatConversation() async {
        let rig = await rig("Tell keyscribe blue to run the tests.")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts == ["to run the tests."])
        #expect(rig.captured.insertedText == nil)
    }

    @Test func insertClipboardContentsAfterANameSendsTheClipboardToThatConversation() async {
        let rig = await rig("Tell keyscribe blue, review this. Insert clipboard contents.", clipboard: "func f() {}")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts.count == 1 && rig.texts[0].hasPrefix("review this") && rig.texts[0].contains("func f() {}"))
    }

    @Test func insertClipboardContentsAloneSendsTheClipboardToTheConversationInFront() async {
        let rig = await rig("Insert clipboard contents.", focused: "claude:s1", clipboard: "func f() {}")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.texts.count == 1 && rig.texts[0].contains("func f() {}") && !rig.texts[0].lowercased().contains("clipboard"))
    }

    @Test func aLeadingNameWithoutTellSendsTheRestToThatConversation() async {
        let rig = await rig("keyscribe what is going on with this right now?", focused: "claude:s2")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["what is going on with this right now?"])
    }

    @Test func equallyStrongAddressesSendToTheAlphabeticallyFirstMatch() async {
        let rig = await rig("Tell blue, run the tests.", focused: "claude:s1",
                      namesFile: #"{"schema_version":1,"names":{"claude:s1":"web blue","claude:s2":"api blue"}}"#)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts == ["run the tests."])
    }

    @Test(arguments: ["Session to run the build", "Keyscrib run the tests"])
    func aMisheardAddressWithoutTellSendsNothingToTheCurrentConversation(transcript: String) async {
        let rig = await rig(transcript, focused: "claude:s2")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
    }

    @Test func aWordThatSoundsLikeTheCurrentConversationSendsTheWholeTakeThere() async {
        let rig = await rig("Keyscrib run the tests", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["Keyscrib run the tests"])
    }

    @Test func aSpokenNameIsNotReplacedByTheCurrentConversationItSoundsLike() async {
        let rig = await rig("Tell keyscribe glue the adapters together", focused: "claude:s2")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["glue the adapters together"])
    }

    private static let twoFirst = #"{"schema_version":1,"names":{"claude:s1":"two","claude:s2":"zeta"}}"#

    @Test func aSentenceStartingWithANumberNameGoesWholeToTheCurrentConversation() async {
        let rig = await rig("Two tests failed.", focused: "claude:s2", namesFile: Self.twoFirst)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts == ["Two tests failed."])
    }

    @Test func tellReachesANumberNameAtADifferentRowAndSessionReachesTheRow() async {
        let told = await rig("Tell two, run tests.", focused: "claude:s2", namesFile: Self.twoFirst)
        defer { try? FileManager.default.removeItem(at: told.supportDir) }
        await take(told)
        #expect(told.sent.map(\.1) == ["claude:s1"])
        #expect(told.texts == ["run tests."])

        let row = await rig("Session two, run tests.", focused: "claude:s1", namesFile: Self.twoFirst)
        defer { try? FileManager.default.removeItem(at: row.supportDir) }
        await take(row)
        #expect(row.sent.map(\.1) == ["claude:s2"])
        #expect(row.texts == ["run tests."])
    }

    @Test func openingANumberNoConversationHasHoldsAndSaysSo() async {
        let focus = Focus()
        let rig = await rig("Open two.", focused: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(focus.sessions.isEmpty)
        #expect(rig.hud.states.contains { if case .error(let message, _, _) = $0 { message == "No conversation named \u{201C}two\u{201D}. Try \u{201C}open keyscribe\u{201D}" } else { false } })
    }

    @Test func sessionBeforeANameAddressesThatConversation() async {
        let rig = await rig("Session keyscribe blue, run unit tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts == ["run unit tests."])
    }

    @Test func openSessionAndANameOpensThatConversation() async {
        let focus = Focus()
        let rig = await rig("Open session keyscribe blue", focused: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(focus.sessions == ["claude:s2"])
    }

    @Test func anUnaddressedTakeGoesToTheConversationFocusedAtThePress() async {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.captured.insertedText == nil)
    }

    private func inFront(
        _ transcript: String = "Run the tests.", modes: [Mode]? = nil, press: TargetSnapshot = terminal,
        glance: any AgentFronting = Front("claude:s2"), engine: (any SpeechEngine)? = nil, frontGrace: Duration = .seconds(1)
    ) async -> Rig {
        await rig(transcript, modes: modes, front: FrontWindow(press), glance: glance, engine: engine, frontGrace: frontGrace)
    }

    private func saidNothingFocused(_ rig: Rig) -> Bool {
        rig.hud.states.contains { state in
            guard case .error(let shown, _, _) = state else { return false }
            return shown.hasPrefix("\(AgentRecipient.nothingFocused). \(AgentOutput.nothingSent) \(AgentRecipient.nothingFocusedAdvice)")
        }
    }

    private final class ScriptedEngine: SpeechEngine, @unchecked Sendable {
        let id = "fixed"
        let displayName = "Scripted"
        let supportsRecognitionBias = false
        private var lines: [String]
        init(_ lines: [String]) { self.lines = lines }
        func loadIfNeeded() async throws {}
        func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { lines.isEmpty ? "" : lines.removeFirst() }
        func evict() async {}
    }

    @Test func anUnaddressedTakeGoesToTheConversationInFront() async {
        let rig = await inFront()
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        let roster = try? #require(rosters(rig).last ?? nil)
        #expect(roster?.rows.map(\.name) == ["keyscribe", "keyscribe blue"])
        #expect(roster?.targetName == "keyscribe blue")
        #expect(fact(await lastHistoryEntry(rig), "Chosen by") == "The conversation in front")
    }

    @Test func anExplicitAddressAffectsOnlyItsOwnRecordingAndTheNextUnnamedOneUsesItsOwnFocus() async {
        let front = Front("claude:s1")
        let rig = await rig("", glance: front, engine: ScriptedEngine(["Tell keyscribe blue to run the tests.", "Run the build."]))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        await take(rig, readingTheFront: true)
        #expect(rig.sent.map(\.1) == ["claude:s2", "claude:s1"])
        #expect(rig.texts == ["to run the tests.", "Run the build."])
    }

    @Test func theNextUnnamedRecordingFollowsTheFocusCapturedAtItsOwnPress() async {
        let front = Front("claude:s1")
        let rig = await rig("Run the tests.", glance: front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        front.answer = Front("claude:s2").answer
        await take(rig, readingTheFront: true)
        #expect(rig.sent.map(\.1) == ["claude:s1", "claude:s2"])
    }

    @Test func focusMovingDuringTheRecordingNeverRedirectsIt() async {
        let front = Front("claude:s1")
        let rig = await rig("Run the tests.", glance: front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        await rig.controller.agentFrontTask?.value
        front.answer = Front("claude:s2").answer
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.map(\.1) == ["claude:s1"])
    }

    @Test func switchingPanesBeforeTheFocusReadLandsHoldsTheInstruction() async {
        let slow = SlowFront()
        let rig = await inFront(glance: slow, frontGrace: .seconds(30))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.inputs.typeNow()
        slow.release.fire()
        await rig.controller.agentFrontTask?.value
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.isEmpty)
        #expect(saidNothingFocused(rig))
        #expect(rosters(rig).compactMap { $0 }.allSatisfy { $0.targetName == nil })
    }

    @Test func inputThatArrivesLateButHappenedBeforeTheReadStillHoldsTheInstruction() async {
        let slow = SlowFront()
        let rig = await inFront(glance: slow, frontGrace: .seconds(30))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        let switchedAt = DispatchTime.now().uptimeNanoseconds
        slow.release.fire()
        await rig.controller.agentFrontTask?.value
        rig.inputs.note(at: switchedAt)
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.isEmpty)
        #expect(saidNothingFocused(rig))
    }

    @Test func lateInputDropsTheConversationInFrontFromTheHUDAtOnce() async {
        let front = Front("claude:s1")
        let rig = await rig("Run the tests.", glance: front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        let switchedAt = (rig.controller.takePressedAt ?? .now()).uptimeNanoseconds + 1
        await rig.controller.agentFrontTask?.value
        #expect(rosters(rig).compactMap { $0 }.last?.targetName == "keyscribe")
        rig.inputs.note(at: switchedAt)
        #expect(rosters(rig).compactMap { $0 }.last?.targetName == nil)
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.isEmpty)
        #expect(saidNothingFocused(rig))
    }

    @Test func aLongTakeKeepsItsConversationInFrontThroughHeavyInputAfterTheRead() async {
        let front = Front("claude:s1")
        let rig = await rig("Run the tests.", glance: front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        await rig.controller.agentFrontTask?.value
        for _ in 0..<300 { rig.inputs.typeNow() }
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.map(\.1) == ["claude:s1"])
    }

    @Test func withoutAWayToSeeInputTheConversationInFrontIsNotTrusted() async {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.inputAfter = { _ in nil }
        await take(rig, readingTheFront: true)
        #expect(rig.sent.isEmpty)
        #expect(!saidNothingFocused(rig))
        #expect(rig.hud.states.contains {
            if case .error(let shown, .openAccessibilitySettings?, _) = $0 { shown.hasPrefix(AgentTake.unconfirmedLine) } else { false }
        })
    }

    @Test func inputAfterTheFocusReadDoesNotUndoIt() async {
        let front = Front("claude:s1")
        let rig = await rig("Run the tests.", glance: front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        await rig.controller.agentFrontTask?.value
        rig.inputs.typeNow()
        front.answer = Front("claude:s2").answer
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.map(\.1) == ["claude:s1"])
    }

    @Test func withNothingFocusedAnExplicitAddressStillSends() async {
        let rig = await rig("Tell keyscribe blue to run the tests.")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
    }

    @Test func withNothingFocusedAnUnnamedInstructionSendsNothingAndSaysWhatToDo() async {
        let rig = await rig("Run the tests.")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
        #expect(saidNothingFocused(rig))
        #expect(AgentRecipient.nothingFocusedLine == "No conversation focused. Open one, or name a conversation in your instruction.")
    }

    @Test(arguments: ["Tell frontend to run the tests.", "Tell session five to run the build."])
    func anUnknownExplicitAddressNeverFallsBackToTheConversationInFront(_ transcript: String) async {
        let rig = await rig(transcript, focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(!saidNothingFocused(rig))
    }

    @Test func anUnavailableExplicitAddressNeverFallsBackToTheConversationInFront() async {
        let rig = await rig("Tell keyscribe blue to run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.disconnect("claude:s2")
        await take(rig)
        #expect(rig.texts.isEmpty)
        #expect(rig.hud.states.contains { if case .error(let shown, _, _) = $0 { shown.hasPrefix("keyscribe blue is disconnected.") } else { false } })
    }

    @Test(arguments: ["Select keyscribe blue.", "Choose keyscribe blue."])
    func selectNoLongerPicksAConversationAndLeavesNothingBehind(_ said: String) async {
        let rig = await rig("", glance: Front("claude:s1"), engine: ScriptedEngine([said, "Run the tests."]))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        await take(rig, readingTheFront: true)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == [said])
        #expect(await lastHistoryEntry(rig)?.summary == "Queued for keyscribe")
    }

    @Test func aFollowTheFrontPhraseIsJustAnInstruction() async {
        let rig = await rig("Follow the front.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["Follow the front."])
    }

    @Test func retainedCommandsLeaveTheNextUnnamedRecordingToItsOwnFocus() async {
        let focus = Focus()
        let front = Front("claude:s1")
        let rig = await rig(
            "", focus: focus, glance: front,
            engine: ScriptedEngine(["Open keyscribe blue.", "Check on keyscribe blue.", "Rename this conversation to builder.", "Run the tests."]))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        for _ in 0..<4 { await take(rig, readingTheFront: true) }
        #expect(focus.sessions == ["claude:s2"])
        #expect(rig.hub.handle(of: "claude:s1") == "builder")
        #expect(rig.sent.map(\.1) == ["claude:s1"])
    }

    @Test func aConversationInFrontThatWasDisconnectedSendsNothing() async {
        let rig = await inFront(glance: Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.disconnect("claude:s1")
        await take(rig, readingTheFront: true)
        #expect(rig.texts.isEmpty)
        #expect(rig.hud.states.contains { if case .error(let shown, _, _) = $0 { shown.hasPrefix("The conversation in front is disconnected.") } else { false } })
    }

    @Test func aSpokenNameWinsOverTheConversationInFront() async {
        let rig = await inFront("Tell keyscribe to run the tests.")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
    }

    @Test func aSpokenNameDoesNotWaitForTheFrontReading() async {
        let slow = SlowFront()
        let rig = await inFront("Tell keyscribe to run the tests.", glance: slow, frontGrace: .seconds(30))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        slow.release.fire()
        #expect(rig.sent.map(\.1) == ["claude:s1"])
    }

    @Test func thePressNeverReadsTheFrontThroughTheReaderThatMayAskForAccess() async {
        let rig = await rig("Run the tests.", front: FrontWindow(Self.terminal), sessionInFront: Front("claude:s2"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(rig.sent.isEmpty)
        #expect(saidNothingFocused(rig))
    }

    @Test(arguments: [
        TargetSnapshot(bundleId: "com.apple.Safari", pid: 4, focusedWindowId: "cg:3"),
        TargetSnapshot(bundleId: "com.mitchellh.ghostty", pid: 9, focusedWindowId: "cg:5"),
    ])
    func aFrontReadingFromAnotherAppOrWindowThanThePressSendsNothing(press: TargetSnapshot) async {
        let rig = await inFront(press: press)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(rig.sent.isEmpty)
        #expect(saidNothingFocused(rig))
    }

    @Test func aConversationInFrontThatIsNotInTheListSendsNothing() async {
        let rig = await inFront(glance: Front("claude:s9"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(rig.sent.isEmpty)
        #expect(saidNothingFocused(rig))
    }

    @Test func aFrontReadingThatDoesNotSettleInTimeSendsNothing() async {
        let slow = SlowFront()
        let rig = await inFront(glance: slow, frontGrace: .milliseconds(50))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        slow.release.fire()
        #expect(rig.sent.isEmpty)
        #expect(saidNothingFocused(rig))
    }

    @Test func aFrontReadingThatLandsAfterReleaseAndGraceWhileTranscribingIsIgnored() async {
        let slow = SlowFront()
        let engine = BlockedEngine()
        let rig = await inFront(glance: slow, engine: engine, frontGrace: .milliseconds(50))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        try? await Task.sleep(for: .milliseconds(150))
        slow.release.fire()
        await rig.controller.agentFrontTask?.value
        engine.release.fire()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.isEmpty)
    }

    @Test func aFrontReadingThatLandsAfterItsTakeWasCancelledNeverReachesTheNextTake() async {
        let slow = SlowFront()
        let rig = await inFront(glance: slow)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        let first = rig.controller.agentFrontTask
        rig.controller.cancel()
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        await rig.controller.agentFrontTask?.value
        slow.release.fire()
        await first?.value
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.isEmpty)
    }

    @Test func anUnknownNameSendsNothingAndInsertsNothing() async {
        let rig = await rig("Tell frontend to run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
    }

    @Test func whileNamesCannotBeLoadedASpokenNameSendsNothing() async {
        let rig = await rig("Tell keyscribe blue to run the tests.", focused: "claude:s1", namesFile: "not json")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
        #expect(rig.hub.directory.conversations.isEmpty)
        #expect(rosters(rig).compactMap { $0 }.last?.namesAvailable == false)
    }

    @Test(arguments: ["Tell my api to run the tests.", "Tell the api to run the tests."])
    func whileNamesCannotBeLoadedANameThatReadsLikeProseStillSendsNothing(transcript: String) async {
        let rig = await rig(transcript, focused: "claude:s1", namesFile: "not json")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
    }

    @Test func whileSavedChoicesCannotBeLoadedEvenARowNumberSendsNothing() async {
        let rig = await rig("Tell session 2 to run the tests.", focused: "claude:s1", namesFile: "not json")
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
        let rig = await rig("Go to Keys Crab Blue.", modes: [mode], focused: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(focus.sessions == ["claude:s2"])
        #expect(rig.sent.isEmpty)
    }

    @Test func aLiveEditRightAfterACorrectedNameReachesTheMessage() async {
        var mode = agentMode()
        mode.replacements = .init(includeGlobal: false, rules: [.init(heard: "Keys Crab", replace: "keyscribe", regex: false)])
        let rig = await rig("Tell Keys Crab Blue insert new line hello", modes: [mode], focused: "claude:s1")
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
        let rig = await rig("tell keyscribe blue slash resume", modes: [slashResumeMode()], focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
        #expect(rig.texts == ["/resume"])
    }

    @Test func aTakeThatIsAWholeUtteranceRuleGoesToTheCurrentConversation() async {
        let rig = await rig("slash resume", modes: [slashResumeMode()], focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts == ["/resume"])
    }

    @Test func verbatimTextThatStartsWithTellIsNeverAnAddress() async {
        let rig = await rig("begin verbatim tell keyscribe blue to stop end verbatim", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s1"])
        #expect(rig.texts.first?.contains("tell keyscribe blue to stop") == true)
    }

    @Test func skippingASlowRewriteSendsTheLocalTextToTheAgentAndNeverPastes() async {
        var mode = agentMode()
        mode.aiRewrite = .init(connection: "c", prompt: "Tidy it.")
        let llm = HangingLLM()
        let rig = await rig(
            "Tell keyscribe blue to run the tests.", modes: [mode],
            connection: Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k"), llm: llm)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
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
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        await llm.started.wait()
        rig.controller.insertLocalTranscriptNow()
        rig.controller.cancel()
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        for _ in 0..<20 { await Task.yield() }
        llm.release.fire()

        #expect(rig.sent.isEmpty)
        #expect(rig.controller.isBusy)
        #expect(!rig.hud.states.contains { $0.primaryText == "The recipient was lost. Nothing sent." })
    }

    @Test func aSkipDuringTheReasoningLookupKeepsTheSkipInTheRecord() async {
        var mode = agentMode()
        mode.aiRewrite = .init(connection: "c", prompt: "Tidy it.")
        let llm = SlowReasoningLLM()
        let rig = await rig(
            "Tell keyscribe blue to run the tests.", modes: [mode],
            connection: Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k"), llm: llm)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
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
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.confirms = false
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        for _ in 0..<200 where rig.sent.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(rig.sent.count == 1)

        rig.controller.cancel()
        rig.hub.handle(.submitted(request: rig.sent[0].0.id, turn: ""))
        await rig.controller.dictationTask?.value
        for _ in 0..<200 where rig.controller.isBusy { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(rig.hud.states.contains(.commandDone(summary: "Sent to keyscribe", detail: "Agent")))
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
        let rig = await rig("", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(!rig.hud.states.contains { if case .error = $0 { true } else { false } })
    }

    @Test func aTakeTheTimeLimitCutsOffIsNeverSentToTheAgent() async {
        let rig = await rig("run the tests", focused: "claude:s1", maxRecordingSeconds: 0.05)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
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
        let rig = await rig("Tell keyscribe blue.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.audio.loseCapture()
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.hud.states.contains(.error(message: "The microphone stopped, so the command did not run.", action: nil)))
    }

    @Test func aMessageToANamedConversationAfterTheMicrophoneStoppedNeitherSendsNorSwitches() async {
        let rig = await rig("Tell keyscribe blue to run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.audio.loseCapture()
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(rig.sent.isEmpty)
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
        let rig = await rig("Switch to keyscribe blue.", focused: "claude:s1", voiceCommands: runner, focus: Focus(.app("Ghostty")),
                      front: FrontWindow(Self.terminal), sessionInFront: Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(runner.recorded.isEmpty)
    }

    @Test func anOpenCancelledWhileItMovesFocusRecordsNoReturnDestination() async {
        let runner = BackRunner()
        let front = FrontWindow(Self.textEdit)
        let focus = Focus()
        let rig = await rig("Switch to keyscribe blue.", focused: "claude:s1", voiceCommands: runner, focus: focus, front: front)
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
        let rig = await rig("Switch to keyscribe blue.", focused: "claude:s1", voiceCommands: runner, focus: Focus(), front: front, sessionInFront: Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        front.snapshot = Self.terminal
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(runner.recorded == [VoiceCommandOrigin(bundleId: "com.apple.TextEdit", pid: 42, windowId: "cg:7")])
    }

    @Test func turningAgentsOffWhileGoingBackLeavesTheControllerFreeForTheNextTake() async {
        let runner = BackRunner()
        let rig = await rig("go back", focused: "claude:s1", voiceCommands: runner, focus: Focus())
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let controller = rig.controller
        runner.whileRunning = {
            var settings = controller.settings
            settings.features.setEnabled(false, for: .agents)
            controller.updateSettings(settings)
        }
        await take(rig)
        #expect(!rig.controller.isBusy)
        #expect(rig.hud.states.last == .hidden)
        #expect(!rig.hud.states.contains(.commandDone(summary: "TextEdit")))
        var settings = controller.settings
        settings.features.setEnabled(true, for: .agents)
        controller.updateSettings(settings)
        runner.whileRunning = {}
        await take(rig)
        #expect(runner.ran.count == 2)
        #expect(rig.hud.states.contains(.commandDone(summary: "TextEdit")))
    }

    @Test func systemSleepAndTurningAgentsOffCloseARunningTerminalScriptGateAtOnce() async {
        let rig = await rig("", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let sleeping = StopGate.watching({ true }, every: .seconds(10))
        rig.controller.handleSystemSleep()
        #expect(!sleeping.isOpen)
        await sleeping.finish()
        let disabled = StopGate.watching({ true }, every: .seconds(10))
        var settings = rig.controller.settings
        settings.features.setEnabled(false, for: .agents)
        rig.controller.updateSettings(settings)
        #expect(!disabled.isOpen)
        await disabled.finish()
    }

    @Test func aSessionWhoseWindowCannotBeReadIsNotAttachedToACapturedWindow() async {
        let runner = BackRunner()
        let rig = await rig("Switch to keyscribe blue.", focused: "claude:s1", voiceCommands: runner, focus: Focus(),
                      front: FrontWindow(Self.terminal), sessionInFront: Front("claude:s1", window: nil))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(runner.recorded.isEmpty)
    }

    @Test func systemSleepWhileGoingBackOnTheAgentTriggerStopsTheReturn() async {
        let runner = BackRunner()
        let rig = await rig("go back", focused: "claude:s1", voiceCommands: runner, focus: Focus())
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

    nonisolated private static let hostApp = TargetSnapshot(bundleId: "dev.example.app", pid: 50, focusedWindowId: "cg:7")

    private func newConversationRig(_ said: String = "Plan the release.", window: String = "cg:7") async -> (Rig, AgentHostTests.FakeHost) {
        let host = AgentHostTests.FakeHost()
        host.window = AgentHostApp(bundle: "dev.example.app", pid: 50, name: "Example", window: window, instance: AgentHostTests.instance)
        let rig = await rig(said, front: FrontWindow(Self.hostApp), hosts: [AgentHostIntegration(kind: AgentHostTests.kind, make: { host })])
        let carrier = AgentHostTests.id("t1")
        rig.hub.handle(.hello(.init(
            protocolVersion: 3, agent: "example", agentVersion: "", instance: "i9", session: carrier, pid: 0, features: ["promptDigest", "start"])))
        rig.hub.handle(.shown(session: carrier, on: false, newConversation: true))
        return (rig, host)
    }

    private func starts(_ rig: Rig) -> [String] {
        rig.sent.compactMap { if case .start(_, _, let text, _) = $0.0 { text } else { nil } }
    }

    @Test func dictationOnAHostsNewConversationPageStartsAConversationThereWithNoKeyPress() async {
        let (rig, host) = await newConversationRig()
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(starts(rig) == ["Plan the release."])
        #expect(rig.returns.pressed.isEmpty)
        #expect(host.delivered.isEmpty)
        #expect(rosters(rig).last??.targetName == "a new Example conversation")
        #expect(rig.hud.states.contains(.commandDone(summary: "Sent to a new Example conversation", detail: "Agent")))
    }

    @Test(arguments: [
        (false, "Example Work doesn\u{2019}t have the \(Branding.appName) plugin. Nothing sent. Agent settings shows how to install it."),
        (true, "Example Work isn\u{2019}t connected. Nothing sent. Agent settings shows its status."),
    ])
    func dictationWithACopyOfAHostInFrontThatCannotBeHeardNamesItAndWhatIsMissing(enrolled: Bool, line: String) async {
        let host = AgentHostTests.FakeHost()
        host.copy = AgentHostCopy(name: "Example Work", instance: "/Users/a/.work", enrolled: enrolled)
        let rig = await rig("Plan the release.", front: FrontWindow(Self.hostApp), hosts: [AgentHostIntegration(kind: AgentHostTests.kind, make: { host })])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.unreachable.insert(AgentSessionID.make(
            agent: "example", native: AgentHostLocation(host: "example", instance: "/Users/a/.work", native: "new conversation").conversationKey))
        await take(rig, readingTheFront: true)
        #expect(starts(rig).isEmpty)
        #expect(rig.hud.states.contains { if case .error(let message, .openAgents?, _) = $0 { message.hasPrefix(line) } else { false } })
    }

    @Test(arguments: [
        (AgentHub.HostCopyNotReady.windowUnknown("Example Work"),
         "\(Branding.appName) can\u{2019}t read which Example Work window is in front. Nothing sent. Click in Example Work\u{2019}s window, then try again.",
         false),
        (.nothingShown("Example Work"),
         "Example Work hasn\u{2019}t shown \(Branding.appName) a conversation. Nothing sent. Open or click in one in Example Work, then try again.",
         false),
        (.notListed("Example Work"),
         "Example Work\u{2019}s conversation in front isn\u{2019}t in its list yet. Nothing sent. Try again in a moment.", false),
        (.cannotStart("Example Work"),
         "Example Work\u{2019}s plugin can\u{2019}t start conversations. Nothing sent. Agent settings can update it.", true),
    ])
    func eachReadinessGapOfACopyInFrontSaysWhatToDo(notReady: AgentHub.HostCopyNotReady, line: String, opensSettings: Bool) async {
        #expect(AgentOutput.notReadyLine(notReady) == line)
        #expect(AgentTake.action(for: notReady, mode: "agent") == (opensSettings ? .openAgents("agent") : nil))
    }

    @Test func aCopyWhoseWindowCannotBeReadWithoutAccessibilityOffersAccessibilitySettings() {
        let notReady = AgentHub.HostCopyNotReady.needsAccessibility("Example Work")
        #expect(AgentOutput.notReadyLine(notReady)
            == "Accessibility is off \u{2014} \(Branding.appName) can\u{2019}t read which Example Work window is in front. Nothing sent.")
        #expect(AgentTake.action(for: notReady, mode: "agent") == .openAccessibilitySettings)
    }

    @Test func dictationWithAConnectedCopyThatReportsNothingInFrontSaysSoInsteadOfNoConversationFocused() async {
        let host = AgentHostTests.FakeHost()
        host.copy = AgentHostCopy(name: "Example Work", instance: "/Users/a/.work", enrolled: true)
        host.window = AgentHostApp(bundle: "dev.example.app", pid: 50, name: "Example", window: "cg:7", instance: "/Users/a/.work")
        let rig = await rig("Plan the release.", front: FrontWindow(Self.hostApp), hosts: [AgentHostIntegration(kind: AgentHostTests.kind, make: { host })])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(starts(rig).isEmpty)
        let line = "Example Work hasn\u{2019}t shown \(Branding.appName) a conversation. Nothing sent."
        #expect(rig.hud.states.contains { if case .error(let message, nil, _) = $0 { message.hasPrefix(line) } else { false } })
    }

    @Test func dictationWithACopyInFrontWhoseDataFolderIsNotSetUpNamesItWithoutSendingTheUserToSettings() async {
        let host = AgentHostTests.FakeHost()
        host.copy = AgentHostCopy(name: "Example Work", instance: "/Users/a/.work", enrolled: false, setUp: false)
        let rig = await rig("Plan the release.", front: FrontWindow(Self.hostApp), hosts: [AgentHostIntegration(kind: AgentHostTests.kind, make: { host })])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(starts(rig).isEmpty)
        let line = "Example Work\u{2019}s data folder isn\u{2019}t set up yet. Nothing sent. Reopen Example Work to set it up."
        #expect(rig.hud.states.contains { if case .error(let message, nil, _) = $0 { message.hasPrefix(line) } else { false } })
    }

    @Test func aNewConversationPageThatLeftTheFrontBeforeSendingIsNeverSentTo() async {
        let (rig, host) = await newConversationRig()
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        await rig.controller.agentFrontTask?.value
        host.window = AgentHostApp(bundle: "dev.example.app", pid: 50, name: "Example", window: "cg:8", instance: AgentHostTests.instance)
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(starts(rig).isEmpty)
        #expect(rig.hud.states.contains { if case .error(let message, _, _) = $0 { message.hasPrefix("Example\u{2019}s page for a new conversation is no longer in front. Nothing sent.") } else { false } })
    }

    @Test func aKeyPressBeforeTheReadLandedKeepsTheNewConversationPageFromCounting() async {
        let (rig, _) = await newConversationRig()
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        let switchedAt = (rig.controller.takePressedAt ?? .now()).uptimeNanoseconds + 1
        await rig.controller.agentFrontTask?.value
        #expect(rosters(rig).compactMap { $0 }.last?.targetName == "a new Example conversation")
        rig.inputs.note(at: switchedAt)
        #expect(rosters(rig).compactMap { $0 }.last?.targetName == nil)
        rig.controller.handleCommit()
        await rig.controller.dictationTask?.value
        #expect(starts(rig).isEmpty)
        #expect(rig.hud.states.contains { if case .error(let message, _, _) = $0 { message.hasPrefix(AgentRecipient.nothingFocused) } else { false } })
    }

    @Test func aNamedConversationStillGoesToThatConversationFromTheNewConversationPage() async {
        let (rig, _) = await newConversationRig("Tell keyscribe, run the tests.")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(starts(rig).isEmpty)
        #expect(rig.texts == ["run the tests."])
    }

    @Test(arguments: [AgentFocusResult.exact, .app("Ghostty"), .unsupported("kitty")])
    func openingAConversationThatMovedFocusRecordsWhereTheUserWasForGoBack(result: AgentFocusResult) async {
        let runner = BackRunner()
        let front = FrontWindow(Self.textEdit)
        let focus = Focus(result)
        focus.whileFocusing = { front.snapshot = Self.terminal }
        let rig = await rig("Switch to keyscribe blue.", focused: "claude:s1", voiceCommands: runner, focus: focus, front: front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(focus.sessions == ["claude:s2"])
        #expect(runner.recorded == [VoiceCommandOrigin(bundleId: "com.apple.TextEdit", pid: 42, windowId: "cg:7")])
        #expect(runner.ran.isEmpty)
    }

    @Test func openingFromAnotherSessionInTheSameWindowRecordsThatSessionAsTheReturn() async {
        let runner = BackRunner()
        let rig = await rig("Switch to keyscribe blue.", focused: "claude:s1", voiceCommands: runner, focus: Focus(),
                      front: FrontWindow(Self.terminal), sessionInFront: Front("claude:s1"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(runner.recorded == [VoiceCommandOrigin(bundleId: "com.mitchellh.ghostty", pid: 9, windowId: "cg:3", session: "claude:s1")])
    }

    @Test func aSessionShownInAnotherWindowOfThePressedTerminalIsNotAttachedToThatWindow() async {
        let runner = BackRunner()
        let rig = await rig("Switch to keyscribe blue.", focused: "claude:s1", voiceCommands: runner, focus: Focus(),
                      front: FrontWindow(Self.terminal), sessionInFront: Front("claude:s1", window: "cg:5"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(runner.recorded.isEmpty)
    }

    @Test func openingTheConversationAlreadyShownRecordsNoReturnDestination() async {
        let runner = BackRunner()
        let rig = await rig("Switch to keyscribe blue.", focused: "claude:s1", voiceCommands: runner, focus: Focus(),
                      front: FrontWindow(Self.terminal), sessionInFront: Front("claude:s2"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(runner.recorded.isEmpty)
    }

    @Test func theRunnerCanReturnToSessionsThroughTheHubWithoutChangingTheRecipient() async {
        let runner = BackRunner()
        let focus = Focus()
        let rig = await rig("", focused: "claude:s1", voiceCommands: runner, focus: focus, sessionInFront: Front("claude:s2"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let sessions = try? #require(runner.sessions)
        #expect(await sessions?.inFront() == FrontSession(id: "claude:s2", app: FrontApp(bundle: "com.mitchellh.ghostty", pid: 9, name: "Ghostty", window: "cg:3")))
        #expect(sessions?.handle("claude:s2") == "keyscribe blue")
        #expect(await sessions?.open("claude:s2", { true }) == .exact)
        #expect(focus.sessions == ["claude:s2"])
    }

    @Test func withAgentsOffTheRunnerHasNoSessionsToReturnTo() async {
        let runner = BackRunner()
        let rig = await rig("", focused: "claude:s1", enabled: false, voiceCommands: runner, focus: Focus(), sessionInFront: Front("claude:s2"))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        #expect(await runner.sessions?.inFront() == nil)
        #expect(await runner.sessions?.open("claude:s2", { true }) == AgentFocusResult.none)
        #expect(runner.sessions?.handle("claude:s2") == nil)
    }

    @Test func openingAConversationAlreadyInFrontKeepsTheEarlierReturnDestination() async {
        let runner = BackRunner()
        let rig = await rig("Switch to keyscribe blue.", focused: "claude:s1", voiceCommands: runner, focus: Focus(), front: FrontWindow(Self.terminal))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(runner.recorded.isEmpty)
    }

    @Test func anOpenThatBroughtNothingForwardRecordsNoReturnDestination() async {
        let runner = BackRunner()
        let front = FrontWindow(Self.textEdit)
        let focus = Focus(.none)
        focus.whileFocusing = { front.snapshot = Self.terminal }
        let rig = await rig("Switch to keyscribe blue.", focused: "claude:s1", voiceCommands: runner, focus: focus, front: front)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(runner.recorded.isEmpty)
    }

    @Test func goBackOnTheAgentTriggerReturnsLocallyAndSendsNothing() async {
        let runner = BackRunner()
        let focus = Focus()
        let rig = await rig("Go back.", focused: "claude:s1", voiceCommands: runner, focus: focus, front: FrontWindow(Self.terminal))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        let entry = await lastHistoryEntry(rig)
        #expect(runner.ran.map(\.transcript) == ["go back"])
        #expect(runner.ran.first?.origin == VoiceCommandOrigin(bundleId: "com.mitchellh.ghostty", pid: 9, windowId: "cg:3"))
        #expect(rig.sent.isEmpty)
        #expect(focus.sessions.isEmpty)
        #expect(rig.hud.states.contains(.commandDone(summary: "TextEdit")))
        #expect(entry?.summary == "Returns to TextEdit.")
        #expect(entry?.outcome == .inserted)
        #expect(fact(entry, "Command") == "Go back")
        #expect(fact(entry, "Conversation in front") == "keyscribe")
    }

    @Test(arguments: ["Go back.", "Repeat that."])
    func aTakeThatNamesNoConversationDoesNotWaitForAPlaceRead(text: String) async {
        let runner = BackRunner()
        runner.outcome = .done(summary: "docs", command: "Replays the last spoken reply.")
        let reader = SlowReader()
        let rig = await rig(text, focused: "claude:s1", voiceCommands: runner, places: reader)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
        rig.controller.placeNamesGrace = .seconds(60)
        reader.blocking = true
        await take(rig)
        #expect(rig.hub.placeTracker?.reading != nil)
        #expect(runner.ran.count == 1)
        reader.blocking = false
        reader.release.signal()
        while let reading = rig.hub.placeTracker?.reading { await reading.value }
    }

    @Test(arguments: ["Repeat that.", "say that again"])
    func repeatThatOnTheAgentTriggerReplaysLocallyAndSendsNothing(text: String) async {
        let runner = BackRunner()
        runner.outcome = .done(summary: "docs", command: "Replays the last spoken reply.")
        let rig = await rig(text, focused: "claude:s1", voiceCommands: runner)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        let entry = await lastHistoryEntry(rig)
        #expect(runner.ran.map(\.transcript) == ["repeat that"])
        #expect(rig.sent.isEmpty)
        #expect(entry?.outcome == .inserted)
        #expect(fact(entry, "Command") == "Repeat that")
        #expect(fact(entry, "Conversation in front") == "keyscribe")
    }

    @Test func renamingThisSessionRenamesTheFocusedConversationAndSendsNothing() async {
        let rig = await rig("Rename this session to Auth Refactor 2.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.handle(of: "claude:s1") == "auth refactor two")
        #expect(rig.hub.handle(of: "claude:s2") == "keyscribe blue")
        #expect(rig.hud.states.contains(.commandDone(summary: "Renamed keyscribe to auth refactor two", detail: "Agent")))
        #expect(entry?.outcome == .inserted)
        #expect(fact(entry, "Command") == "Rename")
        #expect(fact(entry, "New name") == "auth refactor two")
        #expect(fact(entry, "Chosen by") == "The conversation in front")
    }

    @Test func renamingThisSessionRenamesTheConversationInFront() async {
        let rig = await inFront("Rename this session to docs")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.handle(of: "claude:s2") == "docs")
        #expect(rig.hub.handle(of: "claude:s1") == "keyscribe")
        #expect(fact(await lastHistoryEntry(rig), "Chosen by") == "The conversation in front")
    }

    @Test func aRenameIsSavedForTheNextLaunch() async {
        let rig = await rig("Rename this session to docs", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let saved = try? String(contentsOf: rig.supportDir.appendingPathComponent("agents").appendingPathComponent(AgentNameStore.fileName), encoding: .utf8)
        #expect(saved?.contains("docs") == true)
    }

    @Test(arguments: [
        ("Rename this session to keyscribe blue", "Another conversation is already called \u{201C}keyscribe blue\u{201D}"),
        ("Rename this session to session 3", "\u{201C}Conversation\u{201D} or \u{201C}session\u{201D} followed by a number is how you say a row, so it cannot be a name"),
    ])
    func aRenameThatCannotTakeTheNameKeepsTheOldOne(text: String, message: String) async {
        let rig = await rig(text, focused: "claude:s1")
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
            message: "Switch to a conversation, then say the rename command again", action: .openAgents(Mode.agentModeId),
            heard: HeardExcerpt(heard: "Rename this session to docs"))))
    }

    @Test(arguments: [
        ("Rename this session to", "No new name was heard. Nothing sent. Say \u{201C}rename this conversation to\u{201D} and the new name."),
        ("Rename this session to the one we used for the parser yesterday", "A name can be up to 4 words. Nothing sent."),
        ("Rename this session to docs. Run the tests.", "More words followed the name. Nothing sent. Say only the new name after \u{201C}rename this conversation to\u{201D}."),
    ])
    func aRenameWithoutAUsableNameIsHeldAndSendsNothing(text: String, message: String) async {
        let rig = await rig(text, focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.handle(of: "claude:s1") == "keyscribe")
        #expect(rig.hud.states.contains { if case .error(let shown, _, _) = $0 { shown == message } else { false } })
        #expect(entry?.outcome == .failed)
        #expect(fact(entry, "Command") == "Rename")
    }


    @Test(arguments: [
        "Rename this session to docs, scratch that, notes.",
        "Rename this session to docs, scratch that. Rename this session to notes.",
    ])
    func scratchThatInsideARenameCorrectsTheName(text: String) async {
        let rig = await rig(text, focused: "claude:s1")
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
        let rig = await rig("Rename this session to Keys Crab docs", modes: [mode], focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hub.handle(of: "claude:s1") == "keyscribe docs")
    }

    @Test func turningAgentsOffWhileFindingTheConversationInFrontRenamesNothing() async {
        let slow = SlowFront()
        let rig = await inFront("Rename this session to docs", glance: slow, frontGrace: .seconds(30))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        try? await Task.sleep(for: .milliseconds(150))
        var settings = rig.controller.settings
        settings.features.setEnabled(false, for: .agents)
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
        let rig = await rig(text, focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.texts == [sent])
        #expect(rig.hub.handle(of: "claude:s1") == "keyscribe")
    }

    @Test func goBackWithNothingToReturnToSaysSoAndSendsNothing() async {
        let runner = BackRunner()
        runner.outcome = .failed(message: "Nothing to go back to.")
        let rig = await rig("go back", focused: "claude:s1", voiceCommands: runner)
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
        ("Tell keyscribe that sounded wrong", "that sounded wrong"), ("That sounded wrong", "That sounded wrong"),
    ])
    func goBackInsideAMessageIsStillAMessage(text: String, sent: String) async {
        let runner = BackRunner()
        let rig = await rig(text, focused: "claude:s1", voiceCommands: runner)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.texts == [sent])
        #expect(runner.ran.isEmpty)
    }

    @Test func thatSoundedWrongAloneKeepsTheReplyOnlyWhileReplyUpdatesHaveOneToKeep() async {
        let runner = BackRunner()
        runner.outcome = .done(summary: "Kept the reply from keyscribe", command: "Keeps the reply.")
        let rig = await rig("That sounded wrong.", focused: "claude:s1", voiceCommands: runner)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let (output, _) = speaking(rig)
        rig.controller.recordSpokenReply(heard("keyscribe: Done.", origin: nil))
        for _ in 0..<200 where rig.controller.lastHeardReply == nil {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        #expect(rig.controller.lastHeardReply?.conversation == "keyscribe")
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(runner.ran.map(\.transcript) == ["that sounded wrong"])
        withExtendedLifetime(output) {}
    }

    @Test func thatSoundedWrongReachesTheAgentOnceReplyUpdatesAreTurnedOff() async {
        let runner = BackRunner()
        let rig = await rig("That sounded wrong.", focused: "claude:s1", voiceCommands: runner)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        var updatesOn = true
        let (output, _) = speaking(rig, enabled: { updatesOn })
        rig.controller.recordSpokenReply(heard("keyscribe: Done.", origin: nil))
        for _ in 0..<200 where rig.controller.lastHeardReply == nil {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        #expect(rig.controller.lastHeardReply != nil)
        updatesOn = false
        await take(rig)
        #expect(rig.texts == ["That sounded wrong."])
        #expect(runner.ran.isEmpty)
        withExtendedLifetime(output) {}
    }

    @Test func aHeldMessageSaysItsWordsAreKeptAndKeepsThem() async {
        let rig = await rig("Tell frontend to run the tests", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains { state in
            if case .error(let message, _, _) = state { return message.hasSuffix(AgentOutput.keptHint) }
            return false
        })
        #expect(rig.controller.lastResult == "to run the tests")
        #expect(await lastHistoryEntry(rig)?.failureReason?.contains(AgentOutput.keptHint) == false)
    }

    @Test(arguments: ["Cancel.", "never mind", "Please cancel"])
    func cancelAloneSendsNothingAndLeavesACancelledEntry(text: String) async {
        let rig = await rig(text, focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
        #expect(rig.hud.states.contains(.advisory(message: "Cancelled. Nothing sent.")))
        #expect(entry?.outcome == .commandCancelled)
        #expect(entry?.heard == text)
        #expect(entry?.summary == "Cancelled. Nothing sent.")
        #expect(fact(entry, "Command") == "Cancel")
        #expect(fact(entry, "Conversation in front") == "keyscribe")
    }

    @Test func cancelInsideAMessageIsStillAMessage() async {
        let rig = await rig("Tell keyscribe cancel the deployment", focused: "claude:s2")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.texts == ["cancel the deployment"])
    }

    @Test(arguments: ["Keyscribe blue.", "Tell keyscribe blue", "Keyscribe blue, please."])
    func aConversationNameAloneHoldsAndAsksForTheInstruction(text: String) async {
        let rig = await rig(text, focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
        #expect(rig.hud.states.contains { state in
            if case .error(let message, _, _) = state {
                return message == "Only a name was heard: \u{201C}keyscribe blue\u{201D}. Nothing sent. Say your instruction after \u{201C}keyscribe blue\u{201D}, or \u{201C}open keyscribe blue\u{201D} to bring it forward."
            }
            return false
        })
    }

    @Test func openingAConversationBringsItForwardAndSendsNothing() async {
        let focus = Focus()
        let rig = await rig("Switch to keyscribe blue.", focused: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(focus.sessions == ["claude:s2"])
        #expect(rig.sent.isEmpty)
        #expect(rig.captured.insertedText == nil)
        #expect(rig.hud.states.contains(.commandDone(summary: "Opened keyscribe blue", detail: "Agent")))
    }

    @Test(arguments: [AgentFocusResult.app("Ghostty"), .unsupported("kitty"), .notAllowed("Ghostty"), .none])
    func aConversationWhoseTerminalWasNotSelectedSaysSo(result: AgentFocusResult) async {
        let rig = await rig("Open keyscribe blue.", focused: "claude:s1", focus: Focus(result))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains(result.hudState(handle: "keyscribe blue", detail: "Agent")))
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
        let rig = await rig("Open keyscribe blue.", focused: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
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
        let rig = await rig("Open keyscribe blue.", focused: "claude:s1", focus: Focus())
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.hud.states.contains(.transcribing(mode: "Agent", status: "Opening keyscribe blue\u{2026}")))
    }

    @Test func whileATerminalAsksForPermissionTheHUDSaysWhatItIsFor() async {
        let focus = Focus(.exact, asking: "Ghostty")
        let rig = await rig("Open keyscribe blue.", focused: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.hud.states.contains(.transcribing(mode: "Agent", status: "Allow access to Ghostty to open the tab for keyscribe blue")))
    }

    @Test func anOpenVerbFollowedByAnInstructionIsSentAsSaid() async {
        let focus = Focus()
        let rig = await rig("Open the readme and fix the typo.", focused: "claude:s1", focus: focus)
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
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
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
        let notice = HUDState.error(message: "keyscribe isn\u{2019}t connected to \(Branding.appName). Nothing sent.", action: nil, heard: nil)

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
        let sentC = HUDState.commandDone(summary: "Sent to backend", detail: "Agent")

        rig.controller.showAgentNotice(.uncertain("keyscribe"))
        rig.controller.showAgentNotice(.notSent("keyscribe blue", reason: .connectorNotRunning))
        rig.controller.showAgentNotice(.sent("backend"))
        runner.pendingChoice = nil

        for _ in 0..<400 where !rig.hud.states.contains(notSentB) { try? await Task.sleep(for: .milliseconds(5)) }
        let shown = rig.hud.states.filter { [uncertainA, notSentB, sentC].contains($0) }
        #expect(shown == [uncertainA, notSentB])
    }

    private static func notSentNotice(_ handle: String) -> HUDState {
        .error(message: "\(handle) isn\u{2019}t connected to \(Branding.appName). Nothing sent.", action: nil, heard: nil)
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
        let rig = await rig("Tell frontend to run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(entry?.failureReason == "No conversation named \u{201C}frontend\u{201D}. Nothing sent.")
    }

    @Test func aConversationWithoutItsConnectorSaysSoRatherThanSuggestingAReload() async {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.live = false
        rig.hub.refresh()
        await take(rig)
        let expected = "keyscribe isn\u{2019}t connected to \(Branding.appName). Nothing sent."
        #expect(rig.hud.states.contains {
            if case .error(expected, .openAgents?, HeardExcerpt(heard: "Run the tests.")) = $0 { true } else { false }
        })
        #expect(await lastHistoryEntry(rig)?.failureReason == expected)
    }

    private func fact(_ entry: HistoryEntry?, _ label: String) -> String? {
        entry?.facts?.first { $0.label == label }?.value
    }

    @Test func historyRecordsAMessageWithWhereItWentAndHowThatWasChosen() async {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(entry?.summary == "Sent to keyscribe")
        #expect(entry?.result == "Run the tests.")
        #expect(fact(entry, "Command") == "Send message")
        #expect(fact(entry, "Conversation") == "keyscribe \u{00B7} claude \u{00B7} s1")
        #expect(fact(entry, "Chosen by") == "The conversation in front")
        #expect(fact(entry, "Delivery")?.hasPrefix("Handed off at ") == true)
        #expect(fact(entry, "Delivery")?.contains("; confirmed +") == true)
        #expect(entry?.steps == nil)
    }

    @Test func historyRecordsTheSpokenEditsInAMessageBesideWhereItWent() async {
        var mode = agentMode()
        mode.commands.liveEdits = true
        let rig = await rig("Run the tests insert new line then lint.", modes: [mode], focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(fact(entry, "Conversation") == "keyscribe \u{00B7} claude \u{00B7} s1")
        #expect(fact(entry, "Spoken edits") == "new line")
    }

    @Test func historyRecordsAnOpenAsAnOpenWithNothingSent() async {
        let rig = await rig("Open keyscribe blue.", focused: "claude:s1", focus: Focus(.pane(app: "Ghostty", multiplexer: "herdr", uncertain: false)))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig, readingTheFront: true)
        let entry = await lastHistoryEntry(rig)
        #expect(entry?.summary == "Brought Ghostty forward; keyscribe blue\u{2019}s herdr pane not selected")
        #expect(entry?.result == "")
        #expect(fact(entry, "Command") == "Open")
        #expect(fact(entry, "Conversation") == "keyscribe blue \u{00B7} claude \u{00B7} s2")
        #expect(fact(entry, "Conversation in front") == "keyscribe")
    }

    @Test func anOpenThatFindsNoConversationIsRecordedAsAnOpen() async {
        let focus = Focus()
        let rig = await rig("Open two.", focused: "claude:s1", focus: focus)
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
        let rig = await rig(text, focused: "claude:s1", focus: focus)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(focus.sessions.isEmpty)
        #expect(rig.hud.states.contains { if case .error(let message, _, _) = $0 { message == line } else { false } })
        #expect(entry?.summary == recorded)
    }

    @Test func anUnknownNameOffersOneRetryWithTheHighlightedConversationAndOpensItsSettings() async {
        let rig = await rig("Tell frontend to run the tests.", focused: "claude:s2")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error(let message, .openAgents?, _) = $0 {
                message == "No conversation named \u{201C}frontend\u{201D}. Nothing sent. Try \u{201C}tell keyscribe blue, \u{2026}\u{201D}. Your words are kept for Paste last dictation."
            } else { false }
        })
        #expect(entry?.failureReason == "No conversation named \u{201C}frontend\u{201D}. Nothing sent.")
    }

    @Test func aQueuedMessageUpdatesItsOwnEntryWhenItIsSentLater() async {
        let rig = await rig("Run the tests.", focused: "claude:s1", firstStatus: "busy")
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
        #expect(entries.first?.facts?.filter { $0.label != "Delivery" } == queued?.facts)
        #expect(fact(entries.first, "Delivery")?.contains("; confirmed +") == true)
    }

    @Test func anUncertainDeliveryThatLaterSettlesKeepsTheEarlierUncertainty() async {
        let rig = await rig("Run the tests.", focused: "claude:s1", receiptTimeout: .milliseconds(20))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.confirms = false
        await take(rig)
        let uncertain = await lastHistoryEntry(rig)
        #expect(uncertain?.summary == "May not have reached keyscribe: check its terminal")
        #expect(uncertain?.outcome == .failed)

        guard case .submit(let request, _, _, _, _, _, _, _) = rig.sent.first?.0 else { Issue.record("nothing handed off"); return }
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
        let rig = await rig("Run the tests.", focused: "claude:s1", receiptTimeout: .milliseconds(20))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.confirms = false
        await take(rig)
        guard case .submit(let request, _, _, _, _, _, _, _) = rig.sent.first?.0 else { Issue.record("nothing handed off"); return }
        rig.controller.forgetAgentReceipt(request: request)
        rig.controller.showAgentNotice(.sent("keyscribe"), request: request)
        try? await Task.sleep(for: .milliseconds(50))
        rig.controller.waitForHistoryWrites()
        let entry = rig.history.entries().first
        #expect(entry?.summary == "May not have reached keyscribe: check its terminal")
        #expect(entry?.steps == nil)
    }

    private func steeredTake(
        inFront: String? = "claude:s1", features: [String] = ["readiness", "steer"]
    ) async -> (rig: Rig, request: String)? {
        let said = inFront == "claude:s1" ? "Run the tests." : "Tell keyscribe, run the tests."
        let rig = await rig(said, focused: "claude:s1", firstStatus: "busy", glance: Front(inFront))
        rig.hub.handle(.hello(.init(protocolVersion: 1, agent: "claude", agentVersion: "", instance: "i1", session: "claude:s1", pid: 10,
                                    features: features, idle: false, gap: false)))
        await take(rig)
        let sent = await lastHistoryEntry(rig)
        #expect(sent?.summary == "Sent to keyscribe")
        guard case .submit(let request, _, _, _, _, _, _, _) = rig.sent.first?.0 else {
            Issue.record("nothing handed off")
            try? FileManager.default.removeItem(at: rig.supportDir)
            return nil
        }
        return (rig, request)
    }

    @Test func aSteeredTakeTheConversationLaterTurnsAwayNoLongerReadsAsSentInHistory() async {
        guard let (rig, request) = await steeredTake() else { return }
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let kept = "Not sent to keyscribe: its prompt box already has text. Send or clear that text there, then say this again"

        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "aborted", answer: ""))
        rig.hub.handle(.refused(request: request, reason: "draft"))
        for _ in 0..<200 where rig.history.entries().first?.summary == "Sent to keyscribe" {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        let entry = rig.history.entries().first
        #expect(entry?.summary == kept)
        #expect(entry?.steps?.map(\.text) == ["Sent to keyscribe", kept])
    }

    private func leftInBoxAfterEsc(inFront: String?) async -> Rig? {
        guard let (rig, request) = await steeredTake(inFront: inFront, features: ["readiness", "steer", "fill"]) else { return nil }
        rig.returns.typedBy = "claude:s1"
        rig.controller.promptBoxConfirmation = .milliseconds(200)
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "aborted", answer: ""))
        rig.hub.handle(.refused(request: request, reason: "filled"))
        return rig
    }

    private func settled(_ rig: Rig, until done: (HistoryEntry?) -> Bool) async -> HistoryEntry? {
        for _ in 0..<200 where !done(rig.history.entries().first) {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        return rig.history.entries().first
    }

    @Test func aSteeredTakeLeftInThePromptBoxAfterEscIsSentWithReturnWhenItsConversationIsInFront() async {
        guard let rig = await leftInBoxAfterEsc(inFront: "claude:s1") else { return }
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        for _ in 0..<200 where rig.returns.pressed.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        rig.controller.waitForHistoryWrites()
        #expect(rig.returns.pressed == [.return])
        #expect(rig.history.entries().first?.summary == "Sent to keyscribe")
        #expect(rig.history.entries().first?.steps == nil)
    }

    @Test func twoSteeredTakesLeftInOnePromptBoxAfterEscAreSentWithOneReturnAndBothStaySent() async {
        guard let (rig, first) = await steeredTake(features: ["readiness", "steer", "fill"]) else { return }
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        guard case .submit(let second, _, _, _, _, _, _, _) = rig.sent.last?.0, second != first else {
            Issue.record("the second take was not handed off")
            return
        }
        rig.returns.typedBy = "claude:s1"
        rig.controller.promptBoxConfirmation = .milliseconds(200)
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "aborted", answer: ""))
        rig.hub.handle(.refused(request: first, reason: "filled"))
        rig.hub.handle(.refused(request: second, reason: "filled"))
        for _ in 0..<200 where rig.returns.pressed.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(100))
        rig.controller.waitForHistoryWrites()
        #expect(rig.returns.pressed == [.return])
        #expect(rig.history.entries().prefix(2).map(\.summary) == ["Sent to keyscribe", "Sent to keyscribe"])
    }

    @Test func aSteeredTakeLeftInThePromptBoxAfterEscWaitsThereWhenItsConversationIsNotInFront() async {
        guard let rig = await leftInBoxAfterEsc(inFront: "claude:s2") else { return }
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let entry = await settled(rig) { $0?.summary != "Sent to keyscribe" }
        #expect(rig.returns.pressed.isEmpty)
        #expect(entry?.summary?.contains("Press Return there to send it") == true)
    }

    @Test func aSteeredTakeLeftInThePromptBoxAfterEscIsNeverSentWithReturnWhileARecordingIsOpen() async {
        guard let (rig, request) = await steeredTake(features: ["readiness", "steer", "fill"]) else { return }
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.returns.typedBy = "claude:s1"
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "aborted", answer: ""))
        rig.hub.handle(.refused(request: request, reason: "filled"))
        let entry = await settled(rig) { $0?.summary != "Sent to keyscribe" }
        rig.controller.cancel()
        #expect(rig.returns.pressed.isEmpty)
        #expect(entry?.summary?.contains("Press Return there to send it") == true)
    }

    @Test func aSteeredTakeWhoseReplyIsFollowedAfterItsEntryWasWrittenSaysSoInHistory() async {
        guard let (rig, _) = await steeredTake() else { return }
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }

        rig.hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("Run the tests.")))
        for _ in 0..<200 where fact(rig.history.entries().first, "Delivery")?.contains("its reply is followed") != true {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        #expect(fact(rig.history.entries().first, "Delivery")?.contains("its reply is followed") == true)
    }

    @Test func aSteeredTakeTheTurnReadIsNoLongerTrackedForALateOutcome() async {
        guard let (rig, request) = await steeredTake() else { return }
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }

        rig.hub.handle(.absorbed(session: "claude:s1", turn: "t1", prompt: AgentPromptDigest.of("Run the tests.")))
        rig.hub.handle(.refused(request: request, reason: "draft"))
        rig.controller.showAgentNotice(.kept("keyscribe", reason: .composing), request: request)
        try? await Task.sleep(for: .milliseconds(50))
        rig.controller.waitForHistoryWrites()
        let entry = rig.history.entries().first
        #expect(entry?.summary == "Sent to keyscribe")
        #expect(entry?.steps == nil)
    }

    @Test func withHistoryOffALateReceiptStillShowsAndWritesNothing() async {
        let rig = await rig("Run the tests.", focused: "claude:s1", firstStatus: "busy", historyEnabled: false)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        rig.registry.firstStatus = "idle"
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        let sent = HUDState.commandDone(summary: "Sent to keyscribe", detail: "Agent")
        for _ in 0..<200 where !rig.hud.states.contains(sent) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(rig.hud.states.contains(sent))
        rig.controller.waitForHistoryWrites()
        #expect(rig.history.entries().isEmpty)
    }

    @Test func aConfirmationRightBehindAnUncertainReceiptStillReachesHistory() async {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.uncertainThenConfirmed = true
        await take(rig)
        rig.controller.waitForHistoryWrites()
        let entry = await lastHistoryEntry(rig)
        #expect(entry?.summary == "Sent to keyscribe")
        #expect(entry?.outcome == .inserted)
        #expect(entry?.steps?.map(\.text) == ["May not have reached keyscribe: check its terminal", "Sent to keyscribe"])
        #expect(fact(entry, "Delivery")?.contains("; confirmed +") == true)
        #expect(fact(entry, "Delivery")?.contains("not confirmed by +") == true)
    }

    @Test func aQueuedMessageWhoseRewriteFellBackKeepsTheFallbackOnceSent() async {
        var mode = agentMode()
        mode.aiRewrite = .init(connection: "c", prompt: "Tidy it.")
        let rig = await rig(
            "Run the tests.", modes: [mode], focused: "claude:s1",
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
        let rig = await rig("Run the tests.", focused: "claude:s1", firstStatus: "busy")
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
        let rig = await rig("Run the tests.", focused: "claude:s1", receiptTimeout: .milliseconds(20))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.confirms = false
        await take(rig)
        let uncertain = await lastHistoryEntry(rig)
        guard case .submit(let request, _, _, _, _, _, _, _) = rig.sent.first?.0 else { Issue.record("nothing handed off"); return }

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
            "Run the tests.", modes: [mode], focused: "claude:s1",
            connection: Connection(id: "c", name: "C", provider: .gemini, model: "m", keyRef: "k"), llm: llm,
            firstStatus: "busy")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
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
            "Run the tests.", modes: [mode], focused: "claude:s1",
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
        guard case .submit(let request, _, _, _, _, _, _, _) = rig.sent.first?.0 else { Issue.record("nothing handed off"); return }
        rig.hub.handle(.refused(request: request, reason: "busy elsewhere"))
        for _ in 0..<200 where rig.history.entries().first?.outcome != .failed {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        let refused = rig.history.entries().first
        #expect(refused?.outcome == .failed)
        #expect(refused?.failureReason == "keyscribe refused the message. Nothing sent.")
        #expect(refused.flatMap(whyLocalWasKept) == reason)
    }

    @Test func anUnknownNameSaysNothingAboutARunningAgentItDoesNotMatch() async {
        let pi = AgentCandidate(agent: "pi", pid: 40, startedAt: 1, cwd: "/src/reviews", setup: "/Users/me/.pi/agent")
        let rig = await rig("Tell zebra, what is next?", focused: "claude:s1", unconnected: [pi])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        guard case .error(let message, _, _) = rig.hud.states.last else { Issue.record("no error"); return }
        #expect(message.hasPrefix("No conversation named \u{201C}zebra\u{201D}. Nothing sent."))
        #expect(!message.contains("not connected"))
        #expect(!message.contains("reviews"))
        let entry = await lastHistoryEntry(rig)
        #expect(entry?.failureReason?.contains("not connected") == false)
    }

    @Test func aNameMatchingTheFolderOfASessionThatIsNotConnectedNamesOnlyIt() async {
        let pi = AgentCandidate(agent: "pi", pid: 40, startedAt: 1, cwd: "/src/reviews", setup: "/Users/me/.pi/agent")
        let other = AgentCandidate(agent: "pi", pid: 41, startedAt: 1, cwd: "/src/api", setup: "/Users/me/.pi/agent")
        let rig = await rig("Tell review, what is next?", focused: "claude:s1", unconnected: [pi, other])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        guard case .error(let message, let action, _) = rig.hud.states.last else { Issue.record("no error"); return }
        #expect(message == "Pi in reviews isn\u{2019}t connected yet. Nothing sent. Your words are kept for Paste last dictation.")
        #expect(action == .openAgents(Mode.agentModeId, reveal: [pi.rowId]))
    }

    @Test func aNameMatchingTheFolderOfSeveralSessionsThatAreNotConnectedNamesEachOfThem() async {
        let pi = AgentCandidate(agent: "pi", pid: 40, startedAt: 1, cwd: "/src/reviews", setup: "/Users/me/.pi/agent")
        let other = AgentCandidate(agent: "pi", pid: 41, startedAt: 2, cwd: "/work/reviews", setup: "/Users/me/.pi/agent")
        let unrelated = AgentCandidate(agent: "pi", pid: 42, startedAt: 3, cwd: "/src/api", setup: "/Users/me/.pi/agent")
        let rig = await rig("Tell reviews, what is next?", focused: "claude:s1", unconnected: [pi, other, unrelated])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        guard case .error(let message, let action, _) = rig.hud.states.last else { Issue.record("no error"); return }
        #expect(message == "2 Pi conversations in reviews aren\u{2019}t connected yet. Nothing sent. Your words are kept for Paste last dictation.")
        #expect(action == .openAgents(Mode.agentModeId, reveal: [pi.rowId, other.rowId]))
    }

    @Test(arguments: [
        (["Pi"], "Pi in reviews isn\u{2019}t connected yet. Nothing sent."),
        (["Pi", "Claude Code"], "Claude Code in reviews and Pi in reviews aren\u{2019}t connected yet. Nothing sent."),
        (["Pi", "Pi", "Claude Code"], "Claude Code in reviews and 2 Pi conversations in reviews aren\u{2019}t connected yet. Nothing sent."),
    ])
    func theUnconnectedLineNamesEachMatchOnce(agents: [String], line: String) {
        let meant = agents.enumerated().map { index, agent in
            AgentHub.Unconnected(agent: agent, folder: "reviews", row: "\(index)")
        }.sorted { $0.name < $1.name }
        #expect(DictationController.unconnectedLine(meant) == line)
    }

    @Test func aMissingSessionNumberSaysNothingAboutSessionsThatAreNotConnected() async {
        let pi = AgentCandidate(agent: "pi", pid: 40, startedAt: 1, cwd: "/src/reviews", setup: "/Users/me/.pi/agent")
        let rig = await rig("Tell session 7, run the tests.", focused: "claude:s1", unconnected: [pi])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        guard case .error(let message, _, _) = rig.hud.states.last else { Issue.record("no error"); return }
        #expect(!message.contains("not connected"))
    }

    @Test func aNameThatIsFoundSaysNothingAboutSessionsThatAreNotConnected() async {
        let pi = AgentCandidate(agent: "pi", pid: 40, startedAt: 1, cwd: "/src/reviews", setup: "/Users/me/.pi/agent")
        let rig = await rig("Tell keyscribe blue, run the tests.", focused: "claude:s1", unconnected: [pi])
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.map(\.1) == ["claude:s2"])
    }

    @Test func aRefusalAfterQueuingIsSpokenOnceAndKeepsTheMessageInHistory() async {
        let rig = await rig("Run the tests.", focused: "claude:s1", firstStatus: "busy")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let (output, speaker) = speaking(rig)
        rig.transport.confirms = false
        await take(rig)
        #expect(speaker.spoken.isEmpty)
        rig.registry.firstStatus = "idle"
        rig.hub.handle(.turnComplete(session: "claude:s1", reason: "answer", answer: ""))
        await rig.hub.rescan()
        guard case .submit(let request, _, _, _, _, _, _, _) = rig.sent.first?.0 else { Issue.record("nothing handed off"); return }
        rig.hub.handle(.refused(request: request, reason: "draft"))
        for _ in 0..<200 where rig.history.entries().first?.outcome != .failed {
            try? await Task.sleep(for: .milliseconds(5))
            rig.controller.waitForHistoryWrites()
        }
        let line = "Not sent to keyscribe: its prompt box already has text. Send or clear that text there, then say this again"
        #expect(speaker.spoken == ["keyscribe didn\u{2019}t take that: its prompt box has text"])
        let entry = rig.history.entries().first
        #expect(entry?.steps?.map(\.text) == ["Queued for keyscribe", line])
        #expect(entry?.result == "Run the tests.")
        withExtendedLifetime(output) {}
    }

    @Test(arguments: [
        (AgentReceipt.kept("docs", reason: .composing), "docs didn\u{2019}t take that: its prompt box has text" as String?),
        (.kept("docs", reason: .typedSince), "docs didn\u{2019}t take that: you sent it a message since"),
        (.kept("docs", reason: .interrupted), "docs didn\u{2019}t take that: its last turn was stopped"),
        (.kept("docs", reason: .dialog), "docs didn\u{2019}t take that: it has a dialog open"),
        (.kept("docs", reason: .connectionGap), "docs didn\u{2019}t take that: it lost its connection"),
        (.kept("docs", reason: .inPromptBox(.afterStop)), "docs has your message in its prompt box. Press Return there to send it."),
        (.kept("docs", reason: .inPromptBox(.awaitingReturn)), "docs has your message in its prompt box. Press Return there to send it."),
        (.kept("docs", reason: .inPromptBox(.besideText)), "docs has your message in its prompt box. Press Return there to send it."),
        (.notSent("docs", reason: .conversationEnded), "docs didn\u{2019}t take that: it has ended"),
        (.notSent("docs", reason: .connectorNotRunning), "docs didn\u{2019}t take that: it isn\u{2019}t connected"),
        (.notSent("docs", reason: .conversationChanged), "docs didn\u{2019}t take that: it switched conversations"),
        (.notSent("docs", reason: .stopped), "docs didn\u{2019}t take that: after a stopped turn it takes only typed messages"),
        (.notSent("docs", reason: .expired), "docs didn\u{2019}t take that: it timed out"),
        (.notSent("docs", reason: .refused("x")), "docs didn\u{2019}t take that: it wouldn\u{2019}t accept it"),
        (.notSent("docs", reason: .disconnected), "docs didn\u{2019}t take that: it\u{2019}s disconnected"),
        (.notSent(nil, reason: .conversationEnded), "Your message wasn\u{2019}t sent: the conversation has ended"),
        (.notSent(nil, reason: .refused("x")), "Your message wasn\u{2019}t sent: the conversation wouldn\u{2019}t accept it"),
        (.sent("docs"), nil),
        (.queued("docs"), nil),
        (.uncertain("docs"), nil),
    ])
    func eachReceiptHasItsSpokenLine(receipt: AgentReceipt, line: String?) {
        #expect(AgentOutput.spokenRefusal(receipt) == line)
    }

    @Test func aDeliveredMessageIsNotSpoken() async {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let (output, speaker) = speaking(rig)
        await take(rig)
        #expect(rig.hud.states.contains(.commandDone(summary: "Sent to keyscribe", detail: "Agent")))
        #expect(speaker.spoken.isEmpty)
        withExtendedLifetime(output) {}
    }

    @Test func aRefusalAtOnceIsSpokenExactlyOnce() async {
        let rig = await rig("Run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let (output, speaker) = speaking(rig)
        rig.transport.refusal = "draft"
        await take(rig)
        try? await Task.sleep(for: .milliseconds(100))
        rig.controller.waitForHistoryWrites()
        #expect(speaker.spoken == ["keyscribe didn\u{2019}t take that: its prompt box has text"])
        withExtendedLifetime(output) {}
    }

    @Test(arguments: [
        (AgentReceipt.KeptReason.composing, "Not sent to docs: its prompt box already has text. Send or clear that text there, then say this again"),
        (.typedSince, "Not sent to docs: you sent it a message since"),
        (.connectionGap, "Not sent to docs: it lost its connection to \(Branding.appName) while this waited"),
    ])
    func aKeptTakeSaysWhyWithoutPromisingToSendLater(reason: AgentReceipt.KeptReason, message: String) {
        #expect(AgentOutput.receiptState(.kept("docs", reason: reason), mode: "Agent", heard: "") == .advisory(message: message))
    }

    @Test func aSentOrQueuedTakeSaysWhatTheClipboardAdded() {
        let image = AgentOutput.ClipboardNote(images: 1, files: 0, attached: true)
        #expect(AgentOutput.receiptState(.sent("docs"), mode: "Agent", heard: "", clipboard: image)
            == .commandDone(summary: "Sent to docs with 1 image", detail: "Agent"))
        #expect(AgentOutput.receiptState(.queued("docs", waitingOn: .working), mode: "Agent", heard: "", clipboard: image)
            == .commandDone(summary: "Queued for docs with 1 image", detail: "Sends when it finishes"))
        let paths = AgentOutput.ClipboardNote(images: 2, files: 1, attached: false)
        #expect(AgentOutput.receiptState(.sent("docs"), mode: "Agent", heard: "", clipboard: paths)
            == .commandDone(summary: "Sent to docs with the paths to 2 images and 1 file", detail: "Agent"))
        let pdf = AgentOutput.ClipboardNote(images: 0, files: 1, attached: true)
        #expect(AgentOutput.receiptState(.sent("docs"), mode: "Agent", heard: "", clipboard: pdf)
            == .commandDone(summary: "Sent to docs with the path to 1 file", detail: "Agent"))
        #expect(AgentOutput.receiptState(.queued("docs", waitingOn: .working), mode: "Agent", heard: "", clipboard: .init(missed: true))
            == .commandDone(summary: "Queued for docs", detail: "Sends when it finishes. The clipboard had nothing to insert, so \u{201C}insert clipboard contents\u{201D} went as words"))
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
        let rig = await rig("Run the tests.", focused: "claude:s1", firstStatus: "waiting", firstWaitingFor: "permission prompt")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.texts.isEmpty)
        #expect(rig.hud.states.contains(AgentOutput.receiptState(.queued("keyscribe", waitingOn: .approval), mode: "Agent", heard: "")))
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

    private func speaking(
        _ rig: Rig, llm: any LLMClient = HTTPLLMClient(), connection: String = "", enabled: @escaping () -> Bool = { true }
    ) -> (SpokenResultOutput, Speaker) {
        let speaker = Speaker()
        let output = SpokenResultOutput(
            client: llm, permits: { _ in true }, speech: speaker, silencer: SpeechSilencer(),
            settings: { SpokenResultSettings(enabled: enabled(), connection: connection) },
            connection: { $0 == Self.service.id ? Self.service : nil })
        rig.controller.spokenUpdates = output
        return (output, speaker)
    }

    private func showsAnswer(_ rig: Rig, _ line: String) -> Bool {
        rig.hud.states.contains(.advisory(message: line))
    }

    @Test func checkingOnANamedConversationAnswersAndSendsNothing() async {
        let rig = await rig("Okay, check on keyscribe blue.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        let entry = await lastHistoryEntry(rig)
        #expect(rig.sent.isEmpty)
        #expect(showsAnswer(rig, "Status for keyscribe blue: idle. No pending input request is reported. Nothing sent."))
        #expect(entry?.outcome == .inserted)
        #expect(entry?.summary == "Checked keyscribe blue")
        #expect(fact(entry, "Command") == "Check status")
        #expect(fact(entry, "Conversation")?.hasPrefix("keyscribe blue") == true)
        #expect(!(entry?.facts ?? []).contains { $0.value.contains("idle") })
    }

    @Test func checkingOnTheNamedConversationReportsTheApproval() async {
        let rig = await rig(
            "Please check on keyscribe", focused: "claude:s2", firstStatus: "waiting", firstWaitingFor: "permission prompt")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(showsAnswer(rig, "Status for keyscribe: waiting for approval. Nothing sent. Say \u{201C}open keyscribe\u{201D} to see it."))
    }

    @Test func thePendingQuestionIsReadAsAsked() async {
        let rig = await rig("Check on keyscribe.", focused: "claude:s1", firstStatus: "waiting", firstWaitingFor: "custom")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "select", title: "Keep the schema or add a migration?")))
        let (output, speaker) = speaking(rig)
        await take(rig)
        #expect(showsAnswer(rig, "Status for keyscribe: waiting for your answer to \u{201C}Keep the schema or add a migration?\u{201D} Nothing sent. Say \u{201C}open keyscribe\u{201D} to see it."))
        #expect(speaker.spoken == ["Status for keyscribe: waiting for your answer to \u{201C}Keep the schema or add a migration?\u{201D} Nothing sent."])
        withExtendedLifetime(output) {}
    }

    @Test func aPromptWithoutAQuestionIsDescribedThroughTheChosenService() async {
        let rig = await rig("Check on keyscribe.", focused: "claude:s1", firstStatus: "waiting", firstWaitingFor: "custom")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "confirm", tool: "bash", detail: "git push origin main")))
        let (output, _) = speaking(rig, llm: DescribingLLM(), connection: Self.service.id)
        await take(rig)
        #expect(showsAnswer(rig, "Status for keyscribe: Asks whether to allow pushing to main. Nothing sent. Say \u{201C}open keyscribe\u{201D} to see it."))
        withExtendedLifetime(output) {}
    }

    @Test func aDescriptionOfAPromptThatWasReplacedMeanwhileIsNeverShown() async {
        let rig = await rig("Check on keyscribe.", focused: "claude:s1", firstStatus: "waiting", firstWaitingFor: "custom")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "confirm", tool: "bash", detail: "git push origin main")))
        let llm = DescribingLLM()
        let hub = rig.hub
        llm.during = { await MainActor.run { hub.handle(.waiting(session: "claude:s1", prompt: AgentPrompt(kind: "confirm", tool: "bash", detail: "rm -rf build"))) } }
        let (output, _) = speaking(rig, llm: llm, connection: Self.service.id)
        await take(rig)
        #expect(showsAnswer(rig, "Status for keyscribe: waiting for approval. Nothing sent. Say \u{201C}open keyscribe\u{201D} to see it."))
        #expect(!rig.hud.states.contains { $0.primaryText?.contains("pushing") == true })
        withExtendedLifetime(output) {}
    }

    @Test func checkingOnThisConversationChecksTheConversationInFront() async {
        let rig = await rig("Check on this conversation.", focused: "claude:s1", firstStatus: "busy")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(showsAnswer(rig, "Status for keyscribe: working. No pending input request is reported. Nothing sent."))
        #expect(fact(await lastHistoryEntry(rig), "Chosen by") == "The conversation in front")
    }

    @Test func checkingOnThisConversationWithNoConversationInFrontAsksForAName() async {
        let rig = await rig("Check on this conversation.")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error("No conversation focused. Nothing sent. Say \u{201C}check on\u{201D} and a conversation\u{2019}s name.", _, _) = $0 { true } else { false }
        })
    }

    @Test func checkingOnThisConversationWithoutAWayToSeeInputSaysWhy() async {
        let rig = await rig("Check on this conversation.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.inputAfter = { _ in nil }
        await take(rig, readingTheFront: true)
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error(AgentTake.unconfirmedCheckLine, .openAccessibilitySettings?, _) = $0 { true } else { false }
        })
    }

    @Test func renamingWithoutAWayToSeeInputSaysWhyAndKeepsTheName() async {
        let rig = await rig("Rename this conversation to builder.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.inputAfter = { _ in nil }
        await take(rig, readingTheFront: true)
        #expect(rig.hub.handle(of: "claude:s1") == "keyscribe")
        #expect(rig.hud.states.contains {
            if case .error(AgentTake.unconfirmedRenameLine, .openAccessibilitySettings?, _) = $0 { true } else { false }
        })
    }

    @Test func turningAgentsOffWhileFindingTheConversationInFrontAnswersNothing() async {
        let slow = SlowFront()
        let rig = await inFront("Check on this conversation.", glance: slow, frontGrace: .seconds(30))
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.controller.setNextModeOverride(id: Mode.agentModeId)
        rig.controller.handleStart()
        await rig.controller.captureBringUpTask?.value
        rig.controller.handleCommit()
        try? await Task.sleep(for: .milliseconds(150))
        var settings = rig.controller.settings
        settings.features.setEnabled(false, for: .agents)
        rig.controller.updateSettings(settings)
        slow.release.fire()
        await rig.controller.dictationTask?.value
        #expect(!rig.hud.states.contains { if case .advisory = $0 { true } else { false } })
        #expect(!rig.controller.isBusy)
    }

    @Test func aMessageRetryNamesAConversationThatCanReceiveItRatherThanTheHighlightedOneWithoutItsConnector() async {
        let rig = await rig("Tell frontend to run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.unreachable = ["claude:s1"]
        rig.hub.refresh()
        await take(rig)
        #expect(rig.hud.states.contains {
            if case .error(let message, .openAgents?, _) = $0 {
                message == "No conversation named \u{201C}frontend\u{201D}. Nothing sent. Try \u{201C}tell keyscribe blue, \u{2026}\u{201D}. Your words are kept for Paste last dictation."
            } else { false }
        })
    }

    @Test func noConversationThatCanReceiveAMessageLeavesOnlyTheProblemAndTheSettingsButton() async {
        let rig = await rig("Tell frontend to run the tests.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.live = false
        rig.hub.refresh()
        await take(rig)
        #expect(rig.hud.states.contains {
            if case .error("No conversation named \u{201C}frontend\u{201D}. Nothing sent. Your words are kept for Paste last dictation.", .openAgents?, _) = $0 { true } else { false }
        })
    }

    @Test func anOpenRetryStillNamesAConversationWithoutItsConnector() async {
        let rig = await rig("Open frontend.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.live = false
        rig.hub.refresh()
        await take(rig)
        #expect(rig.hud.states.contains {
            if case .error("No conversation named \u{201C}frontend\u{201D}. Try \u{201C}open keyscribe\u{201D}", .openAgents?, _) = $0 { true } else { false }
        })
    }

    @Test func aDisconnectedConversationIsNeverOfferedAsTheRetry() async {
        let rig = await rig("Tell frontend to run the tests.")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.disconnect("claude:s1")
        await take(rig)
        #expect(rig.hud.states.contains {
            if case .error(let message, _, _) = $0 {
                message == "No conversation named \u{201C}frontend\u{201D}. Nothing sent. Try \u{201C}tell keyscribe blue, \u{2026}\u{201D}. Your words are kept for Paste last dictation."
            } else { false }
        })
    }

    @Test func aDisconnectedConversationIsReportedAsDisconnectedNotEnded() async {
        let rig = await rig("Check on keyscribe blue.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.hub.disconnect("claude:s2")
        await take(rig)
        #expect(rig.texts.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error("keyscribe blue is disconnected. Nothing sent.", .openAgents?, _) = $0 { true } else { false }
        })
    }

    @Test(arguments: [
        ("Check on frontend.", "No conversation named \u{201C}frontend\u{201D}. Nothing sent."),
        ("Check on conversation nine.", "There is no conversation 9. Nothing sent."),
    ])
    func checkingOnAConversationThatIsNotThereHoldsKeepsTheWordsAndLeavesTheRecipient(text: String, problem: String) async {
        let rig = await rig(text, focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error(let message, _, _) = $0 { message.hasPrefix(problem) && message.hasSuffix(AgentOutput.keptHint) } else { false }
        })
        #expect(rig.controller.lastResult == text)
        #expect(await lastHistoryEntry(rig)?.outcome == .failed)
    }

    @Test func checkingOnANameWhileNamesCannotBeLoadedHoldsAndKeepsTheWords() async {
        let rig = await rig("Check on keyscribe blue.", focused: "claude:s1", namesFile: "not json")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error(let message, _, _) = $0 {
                message.hasPrefix("Couldn\u{2019}t check conversation names yet. Nothing sent.") && message.hasSuffix(AgentOutput.keptHint)
            } else { false }
        })
        #expect(rig.controller.lastResult == "Check on keyscribe blue.")
    }

    @Test func theBeforeANameWithoutABreakIsHeldRatherThanSentToTheCurrentConversation() async {
        let rig = await rig("Tell the keyscribe blue run the tests", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(rig.hud.states.contains {
            if case .error(let message, _, _) = $0 { message.hasPrefix("Did you mean \u{201C}keyscribe blue\u{201D}?") } else { false }
        })
        let row = await self.rig("Tell the session two run the tests", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: row.supportDir) }
        await take(row)
        #expect(row.sent.isEmpty)
        let sameRecipient = await self.rig("Tell the keyscribe blue run the tests", focused: "claude:s2")
        defer { try? FileManager.default.removeItem(at: sameRecipient.supportDir) }
        await take(sameRecipient)
        #expect(sameRecipient.texts == ["Tell the keyscribe blue run the tests"])
    }

    @Test func aSpokenAnswerIsDroppedWhenTheConnectorGoesAwayBeforeItPlays() async {
        let rig = await rig("Check on keyscribe.", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let silencer = SpeechSilencer()
        let speaker = Speaker()
        let output = SpokenResultOutput(
            client: HTTPLLMClient(), permits: { _ in true }, speech: speaker, silencer: silencer,
            settings: { SpokenResultSettings(enabled: true) }, connection: { _ in nil })
        rig.controller.spokenUpdates = output
        silencer.recordingStarted()
        await take(rig)
        #expect(showsAnswer(rig, "Status for keyscribe: idle. No pending input request is reported. Nothing sent."))
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
            "Check on keyscribe.", focused: "claude:s2", firstStatus: "waiting", firstWaitingFor: "permission prompt", firstPid: running)
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.registry.unreadable = true
        await rig.hub.rescan()
        await take(rig)
        #expect(showsAnswer(rig, "Status for keyscribe: last seen waiting for approval. Its current status is unavailable. Nothing sent."))
        let who = await self.rig("Who needs me?", focused: "claude:s2", firstStatus: "waiting", firstWaitingFor: "permission prompt", firstPid: running)
        defer { try? FileManager.default.removeItem(at: who.supportDir) }
        who.registry.unreadable = true
        await who.hub.rescan()
        await take(who)
        #expect(showsAnswer(who, "Status for all conversations: no pending input requests are reported, but some conversations couldn\u{2019}t be checked. Nothing sent."))
    }

    @Test func whoNeedsMeIsNotSpokenOnceItCouldNoLongerCheckEveryConversation() async {
        let rig = await rig("Who needs me?", focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        let silencer = SpeechSilencer()
        let speaker = Speaker()
        let output = SpokenResultOutput(
            client: HTTPLLMClient(), permits: { _ in true }, speech: speaker, silencer: silencer,
            settings: { SpokenResultSettings(enabled: true) }, connection: { _ in nil })
        rig.controller.spokenUpdates = output
        silencer.recordingStarted()
        await take(rig)
        #expect(showsAnswer(rig, "Status for all conversations: no pending input requests are reported. Nothing sent."))
        rig.registry.unreadable = true
        await rig.hub.rescan()
        silencer.recordingEnded()
        for _ in 0..<200 { await Task.yield() }
        #expect(speaker.spoken.isEmpty)
        withExtendedLifetime(output) {}
    }

    @Test func whoNeedsMeCountsAWaitingConversationWithoutItsConnector() async {
        let rig = await rig("Who needs me?", focused: "claude:s2", firstStatus: "waiting", firstWaitingFor: "permission prompt")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        rig.transport.live = false
        rig.hub.refresh()
        await take(rig)
        #expect(showsAnswer(rig, "Status for all conversations: one needs you: keyscribe. Some conversations couldn\u{2019}t be checked. Nothing sent."))
    }

    @Test func whoNeedsMeNamesTheConversationsWaitingForInput() async {
        let rig = await rig("Check on all conversations.", focused: "claude:s2", firstStatus: "waiting", firstWaitingFor: "permission prompt")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.sent.isEmpty)
        #expect(showsAnswer(rig, "Status for all conversations: one needs you: keyscribe. Nothing sent."))
        let entry = await lastHistoryEntry(rig)
        #expect(fact(entry, "Command") == "Check status")
        #expect(fact(entry, "Conversation") == "All conversations")
    }

    @Test(arguments: [
        ("Tell keyscribe what it is waiting for", "what it is waiting for"),
        ("What is the build waiting for?", "What is the build waiting for?"),
        ("What is frontend waiting for?", "What is frontend waiting for?"),
        ("Ask keyscribe what it needs, then review the changes.", "what it needs, then review the changes."),
        ("Do you need anything from me?", "Do you need anything from me?"),
        ("What are you waiting for?", "What are you waiting for?"),
        ("What does keyscribe blue need from me?", "What does keyscribe blue need from me?"),
        ("What does keyscribe blue need from me to continue?", "What does keyscribe blue need from me to continue?"),
        ("Who's stuck?", "Who's stuck?"),
        ("Tell keyscribe check on keyscribe blue", "check on keyscribe blue"),
        ("Before you change anything, check on keyscribe blue and say what it needs.", "Before you change anything, check on keyscribe blue and say what it needs."),
    ])
    func aQuestionThatIsNotAStatusCheckIsSentAsAMessage(text: String, sent: String) async {
        let rig = await rig(text, focused: "claude:s1")
        defer { try? FileManager.default.removeItem(at: rig.supportDir) }
        await take(rig)
        #expect(rig.texts == [sent])
    }
}
