import Foundation
import KeyScribeKit

final class ScriptedCapture: AudioCapturing, @unchecked Sendable {
    private let microphone: AudioCapturing
    private let lock = NSLock()
    private var armed: URL?
    private var active: URL?
    private var drainedScripted = false

    init(_ microphone: AudioCapturing) {
        self.microphone = microphone
    }

    func arm(_ clip: URL) { lock.withLock { armed = clip } }

    func disarm() { lock.withLock { armed = nil } }

    func start(sampleRate: Int) async throws -> URL {
        try await start(sampleRate: sampleRate, wantsSamples: false)
    }

    func start(sampleRate: Int, wantsSamples: Bool) async throws -> URL {
        guard let clip = lock.withLock({ () -> URL? in
            defer { armed = nil }
            return armed
        }) else {
            lock.withLock { drainedScripted = false }
            return try await microphone.start(sampleRate: sampleRate, wantsSamples: wantsSamples)
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-scripted-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: clip, to: copy)
        lock.withLock { active = copy }
        return copy
    }

    private func takeActive() -> URL? {
        lock.withLock {
            defer { active = nil }
            if active != nil { drainedScripted = true }
            return active
        }
    }

    private var isActive: Bool { lock.withLock { active != nil } }

    func stop() -> URL? { takeActive() ?? microphone.stop() }

    func finishDraining() async -> URL? {
        if let active = takeActive() { return active }
        return await microphone.finishDraining()
    }

    func takeDrainedSamples() -> [Float]? {
        lock.withLock { drainedScripted } ? nil : microphone.takeDrainedSamples()
    }

    var currentLevel: Float { isActive ? 0 : microphone.currentLevel }
    var currentInputName: String? { isActive ? nil : microphone.currentInputName }
    var inputIsBluetooth: Bool { microphone.inputIsBluetooth }
    func prewarm() { microphone.prewarm() }
    func refreshBinding() { microphone.refreshBinding() }
    func releaseWarm() { microphone.releaseWarm() }
    func setPreferredInputUID(_ uid: String?) { microphone.setPreferredInputUID(uid) }
    func setCaptureLostHandler(_ handler: @escaping @Sendable () -> Void) { microphone.setCaptureLostHandler(handler) }
}

struct ScriptedEngine: SpeechEngine {
    let base: any SpeechEngine
    let transcript: String

    var id: String { base.id }
    var displayName: String { base.displayName }
    var supportsRecognitionBias: Bool { base.supportsRecognitionBias }
    var captureSampleRate: Int { base.captureSampleRate }
    var benefitsFromWarmupClip: Bool { base.benefitsFromWarmupClip }
    var installDirNames: [String] { base.installDirNames }
    func verifyInstalled(in modelsDir: URL) -> Bool? { base.verifyInstalled(in: modelsDir) }
    func loadIfNeeded() async throws { try await base.loadIfNeeded() }
    func load(progress: (@Sendable (ModelLoadProgress) -> Void)?) async throws { try await base.load(progress: progress) }
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { transcript }
    func evict() async { await base.evict() }
    func prepareForDictation() async { await base.prepareForDictation() }
}

final class ScriptedEngines: @unchecked Sendable {
    private let lock = NSLock()
    private var armed: String?

    func arm(_ transcript: String?) { lock.withLock { armed = transcript } }

    func engine(for active: any SpeechEngine) -> any SpeechEngine {
        guard let transcript = lock.withLock({ () -> String? in
            defer { armed = nil }
            return armed
        }) else { return active }
        return ScriptedEngine(base: active, transcript: transcript)
    }
}

struct ScriptedTakeRequest: Codable, Equatable, Sendable {
    var id: String
    var wav: String
    var transcript: String?
    var mode: String?
    var caller: Int32
    var issued: Date
}

struct ScriptedTakeMode: Equatable {
    var id: String
    var sendsToAgents: Bool
}

struct ScriptedTakeResult: Codable, Equatable, Sendable {
    var id: String
    var ok: Bool
    var outcome: String?
    var receipt: String?
    var hud: String?
    var problem: String?
}

struct ScriptedTakeMarks {
    var records: Int
    var record: DictationRecord?
    var receipts: Int
    var receipt: AgentReceipt?
    var hud: String?
}

@MainActor
protocol ScriptedTakeTarget: AnyObject {
    func scriptedTakeMode(_ named: String?) -> ScriptedTakeMode?
    func setNextModeOverride(id: String?)
    func pressForScriptedTake()
    func releaseForScriptedTake()
    var isRecordingForScriptedTake: Bool { get }
    var isIdleForScriptedTake: Bool { get }
    func finishScriptedTake() async
    var scriptedTakeMarks: ScriptedTakeMarks { get }
}

@MainActor
final class ScriptedTakeRunner {
    private let target: ScriptedTakeTarget
    private let capture: ScriptedCapture
    private let engines: ScriptedEngines
    private let agentModesOnly: Bool
    private let pause: Duration
    private let recordingWithin: Duration

    private let callerWaits: (Int32, Date) -> Bool

    init(
        target: ScriptedTakeTarget, capture: ScriptedCapture, engines: ScriptedEngines, agentModesOnly: Bool = true,
        pause: Duration = .milliseconds(20),
        recordingWithin: Duration = .seconds(10), callerWaits: @escaping (Int32, Date) -> Bool = ScriptedTakeRunner.callerWaits
    ) {
        self.callerWaits = callerWaits
        self.target = target
        self.capture = capture
        self.engines = engines
        self.agentModesOnly = agentModesOnly
        self.pause = pause
        self.recordingWithin = recordingWithin
    }

    func run(_ request: ScriptedTakeRequest) async -> ScriptedTakeResult? {
        guard callerWaits(request.caller, request.issued) else { return nil }
        func refused(_ problem: String) -> ScriptedTakeResult { ScriptedTakeResult(id: request.id, ok: false, problem: problem) }
        guard target.isIdleForScriptedTake else { return refused("A dictation is already running.") }
        guard FileManager.default.isReadableFile(atPath: request.wav) else { return refused("The clip \(request.wav) can\u{2019}t be read.") }
        guard let mode = target.scriptedTakeMode(request.mode) else {
            return refused(request.mode.map { "No enabled mode is named \u{201C}\($0)\u{201D}." } ?? "No enabled mode sends to agents.")
        }
        guard mode.sendsToAgents || !agentModesOnly else {
            return refused("This build makes scripted takes only in a mode that sends to agents, and \u{201C}\(request.mode ?? mode.id)\u{201D} doesn\u{2019}t.")
        }
        let before = target.scriptedTakeMarks
        capture.arm(URL(fileURLWithPath: request.wav))
        engines.arm(request.transcript)
        defer {
            capture.disarm()
            engines.arm(nil)
        }
        target.setNextModeOverride(id: mode.id)
        target.pressForScriptedTake()
        let clock = ContinuousClock()
        let deadline = clock.now + recordingWithin
        while !target.isRecordingForScriptedTake, !target.isIdleForScriptedTake, clock.now < deadline {
            try? await Task.sleep(for: pause)
        }
        guard target.isRecordingForScriptedTake else {
            target.releaseForScriptedTake()
            return report(request, mode: mode, before: before, problem: "The take never started recording.")
        }
        target.releaseForScriptedTake()
        await target.finishScriptedTake()
        return report(request, mode: mode, before: before, problem: nil)
    }

    private func report(_ request: ScriptedTakeRequest, mode: ScriptedTakeMode, before: ScriptedTakeMarks, problem: String?) -> ScriptedTakeResult {
        let after = target.scriptedTakeMarks
        let record = after.records > before.records ? after.record : nil
        let receipt = after.receipts > before.receipts ? after.receipt : nil
        let succeeded = record?.outcome.map(Self.succeeded) ?? false
        let sent = receipt.map(Self.sent) ?? !mode.sendsToAgents
        let ok = problem == nil && succeeded && sent
        let why = problem ?? (record == nil ? "The take finished without a result." : ok ? nil : "The take did not deliver.")
        return ScriptedTakeResult(
            id: request.id, ok: ok, outcome: record?.outcome?.rawValue, receipt: receipt.map { String(describing: $0) }, hud: after.hud,
            problem: why)
    }

    nonisolated static func callerWaits(_ pid: Int32, issued: Date) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard case .started(let milliseconds) = ProcessStart.read(pid: Int(pid)) else { return false }
        return Double(milliseconds) / 1000 <= issued.timeIntervalSince1970 + 1
    }

    private static func succeeded(_ outcome: DictationRecord.Outcome) -> Bool {
        switch outcome {
        case .inserted, .copied, .command, .answered: true
        case .localFallback, .noSpeech, .failed: false
        }
    }

    private static func sent(_ receipt: AgentReceipt) -> Bool {
        switch receipt {
        case .sent, .sentWithDraft: true
        case .queued, .kept, .notSent, .uncertain: false
        }
    }
}

@MainActor
final class ScriptedTakeInbox {
    nonisolated static let folderName = "scripted-takes"
    nonisolated static let requestSuffix = ".request.json"
    nonisolated static let resultSuffix = ".result.json"

    nonisolated static func folder(supportDir: URL) -> URL {
        supportDir.appendingPathComponent(folderName, isDirectory: true)
    }

    nonisolated static let longestWait: TimeInterval = 600

    private let folder: URL
    private let runner: ScriptedTakeRunner
    private let now: () -> Date
    private var source: DispatchSourceFileSystemObject?
    private var running = false

    init(folder: URL, runner: ScriptedTakeRunner, now: @escaping () -> Date = Date.init) {
        self.folder = folder
        self.runner = runner
        self.now = now
    }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        drain()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func pending() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(Self.requestSuffix) }.sorted().map { folder.appendingPathComponent($0) }
    }

    private func clearStaleResults() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(Self.resultSuffix) {
            let url = folder.appendingPathComponent(name)
            let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let written, now().timeIntervalSince(written) > Self.longestWait { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func drain() {
        clearStaleResults()
        guard !running, let next = pending().first else { return }
        running = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let data = FileManager.default.contents(atPath: next.path)
            try? FileManager.default.removeItem(at: next)
            let id = String(next.lastPathComponent.dropLast(Self.requestSuffix.count))
            let result: ScriptedTakeResult?
            if let request = data.flatMap({ try? JSONDecoder().decode(ScriptedTakeRequest.self, from: $0) }), request.id == id {
                result = await self.runner.run(request)
            } else {
                result = ScriptedTakeResult(id: id, ok: false, problem: "The request couldn\u{2019}t be read.")
            }
            if let result, let encoded = try? JSONEncoder().encode(result) {
                try? encoded.write(to: self.folder.appendingPathComponent(id + Self.resultSuffix), options: .atomic)
            }
            self.running = false
            self.drain()
        }
    }
}

enum ScriptedTakeCLI {
    static func run(text: String?, wav: String?, mode: String?, timeout: TimeInterval, supportDir: URL, allowed: Bool) -> Int32 {
        guard allowed else {
            print("agent-take: this build doesn\u{2019}t take scripted takes. Use a development build: KeyScribeDev, or a build whose target sets KEYSCRIBE_DEVELOPMENT_TOOLS to YES.")
            return 2
        }
        let folder = ScriptedTakeInbox.folder(supportDir: supportDir)
        let id = "take-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"
        var clip = wav.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var spoken: URL?
        if clip == nil, let text {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).wav")
            guard speak(text, into: url) else {
                print("agent-take: macOS couldn\u{2019}t speak the text into a clip")
                return 1
            }
            spoken = url
            clip = url.path
        }
        defer { if let spoken { try? FileManager.default.removeItem(at: spoken) } }
        guard let clip else { return 2 }
        let timeout = min(timeout, ScriptedTakeInbox.longestWait)
        let request = ScriptedTakeRequest(id: id, wav: clip, transcript: wav == nil ? text : nil, mode: mode, caller: getpid(), issued: Date())
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let pending = folder.appendingPathComponent("\(id).pending")
            try JSONEncoder().encode(request).write(to: pending, options: .atomic)
            try FileManager.default.moveItem(at: pending, to: folder.appendingPathComponent(id + ScriptedTakeInbox.requestSuffix))
        } catch {
            print("agent-take: couldn\u{2019}t write the request: \(error.localizedDescription)")
            return 1
        }
        let resultURL = folder.appendingPathComponent(id + ScriptedTakeInbox.resultSuffix)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = FileManager.default.contents(atPath: resultURL.path), let result = try? JSONDecoder().decode(ScriptedTakeResult.self, from: data) {
                try? FileManager.default.removeItem(at: resultURL)
                let said = [result.outcome, result.receipt, result.hud].compactMap { $0 }.joined(separator: " \u{2014} ")
                print(result.ok ? "agent-take: \(said)" : "agent-take: not delivered \u{2014} \(result.problem ?? "")\(said.isEmpty ? "" : " \u{2014} " + said)")
                return result.ok ? 0 : 1
            }
            usleep(100_000)
        }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id + ScriptedTakeInbox.requestSuffix))
        print("agent-take: no answer within \(Int(timeout)) s. Run this with the development build's own binary while that app is running.")
        return 1
    }

    private static func speak(_ text: String, into url: URL) -> Bool {
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEI16@16000", "--", text]
        guard (try? say.run()) != nil else { return false }
        say.waitUntilExit()
        return say.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
    }
}
