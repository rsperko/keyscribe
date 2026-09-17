import Accelerate
import AVFoundation
import CoreML
import FluidAudio
import Foundation
import KeyScribeKit

struct SpeechPresenceReading: Sendable {
    let presence: SpeechPresence
    let peak: Float
    let latencyMs: Double
    let modelUsed: Bool
    // Where speech began, when the model ran and found it after provable leading silence — the evidence the
    // empty-transcript recovery trims on. Nil when the model didn't run, no chunk cleared the gate, or speech
    // started in chunk zero. Wall-clock: the detector resamples to 16 kHz before chunking, so a 24 kHz capture
    // (Qwen3) still reads back in take time.
    var speechStart: TimeInterval? = nil
    var chunkProbabilities: [Float] = []

    // Derived, never stored: a reading that carries the vector cannot disagree with itself about its max.
    var maxProbability: Float { chunkProbabilities.max() ?? 0 }
}

protocol SpeechPresenceDetecting: Sendable {
    func read(samples: [Float]?, url: URL, sampleRate: Int) async -> SpeechPresenceReading
    func prewarm() async
}

extension SpeechPresenceDetecting {
    func prewarm() async {}
}

struct SpeechPresenceManager: Sendable {
    let process: @Sendable ([Float]) async throws -> [Float]

    init(process: @escaping @Sendable ([Float]) async throws -> [Float]) {
        self.process = process
    }
}

enum VADModel {
    static let dirName = Repo.vad.folderName

    // PINNED, deliberately not ModelNames.VAD.sileroVadFile. FluidAudio PR #734 swapped the SDK's default
    // Silero artifact v6.0.0 -> v6.2.1 (one line, no logic change). v6.2.1 is tuned recall-first at
    // upstream's ~0.85 threshold; KeyScribe's no-speech gate reads raw probabilities at 0.30, deep in a
    // tail upstream never optimizes, and there v6.2.1 scores breaths and stray clicks as speech —
    // measured, it flipped blip_breath_03 and dbl_gap15 and failed the corpus/blips gate 2/23.
    // ModelHub.loadModels unions caller-supplied names beyond the repo's required set, so naming the
    // older artifact keeps gate behavior byte-identical across SDK bumps. Changing this string is a
    // gate change: re-run `--vad-probe corpus/blips` AND `corpus/commands` before touching it.
    static let pinnedArtifact = "silero-vad-unified-256ms-v6.0.0.mlmodelc"

    static func modelURL(in modelsDir: URL) -> URL {
        modelsDir
            .appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent(pinnedArtifact, isDirectory: true)
    }

    static func isPresent(in modelsDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(in: modelsDir).path)
    }

    static func load(
        in modelsDir: URL,
        progressHandler: ProgressHandler? = nil
    ) async throws -> MLModel {
        let models = try await ModelHub.loadModels(
            .vad, modelNames: [pinnedArtifact],
            directory: modelsDir, progressHandler: progressHandler)
        guard let model = models[pinnedArtifact] else {
            throw VadError.modelLoadingFailed
        }
        return model
    }

    @discardableResult
    static func ensureDownloaded(in modelsDir: URL) async -> Bool {
        do {
            _ = try await load(in: modelsDir)
            Log.models.notice("vad model ready")
            return true
        } catch {
            Log.models.error(
                "vad model ensure failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func ensureInBackground(in modelsDir: URL) {
        guard !isPresent(in: modelsDir) else { return }
        Task.detached(priority: .utility) { await ensureDownloaded(in: modelsDir) }
    }
}

actor SpeechPresenceDetector: SpeechPresenceDetecting {
    private enum SkipReason: String, Error {
        case noModel = "no-model"
        case loadDeadline = "load-deadline"
        case busy, deadline, unreadable, failed, cancelled
    }

    // Inference is one model call per 256 ms chunk, so its cost grows with the take; a flat budget
    // silently turned the gate off on long takes. The load has its own budget so a cold model never
    // spends the inference window.
    private let deadlineSeconds: Double
    private let deadlinePerAudioSecond: Double
    private let loadDeadlineSeconds: Double
    private let loadRetryBaseSeconds: Double
    private let now: @Sendable () -> Date
    private let modelPresent: @Sendable () -> Bool
    private let loadManager: @Sendable () async throws -> SpeechPresenceManager
    private let prepareInput: @Sendable ([Float]?, URL, Int) async throws -> [Float]
    private let preparationGate = SingleFlightDeadline()
    private let inferenceGate = SingleFlightDeadline()
    private var manager: SpeechPresenceManager?
    private var managerTask: Task<SpeechPresenceManager, Error>?
    private var loadFailureCount = 0
    private var retryAfter: Date?

    init(
        modelsDir: URL,
        deadlineSeconds: Double = 0.25,
        deadlinePerAudioSecond: Double = 0.003,
        loadDeadlineSeconds: Double = 1,
        loadRetryBaseSeconds: Double = 1,
        now: @escaping @Sendable () -> Date = { Date() },
        modelPresent: (@Sendable () -> Bool)? = nil,
        loadManager: (@Sendable () async throws -> SpeechPresenceManager)? = nil,
        prepareInput: (@Sendable ([Float]?, URL, Int) async throws -> [Float])? = nil
    ) {
        self.prepareInput = prepareInput ?? { samples, url, sampleRate in
            try Self.vadInput(samples: samples, url: url, sampleRate: sampleRate)
        }
        self.deadlineSeconds = deadlineSeconds
        self.deadlinePerAudioSecond = deadlinePerAudioSecond
        self.loadDeadlineSeconds = loadDeadlineSeconds
        self.loadRetryBaseSeconds = loadRetryBaseSeconds
        self.now = now
        self.modelPresent = modelPresent ?? { VADModel.isPresent(in: modelsDir) }
        self.loadManager = loadManager ?? {
            let manager = VadManager(
                config: .default, vadModel: try await VADModel.load(in: modelsDir))
            return SpeechPresenceManager { samples in
                try await manager.process(samples).map(\.probability)
            }
        }
    }

    func prewarm() async {
        _ = await ensureManager()
    }

    func inferenceInFlight() async -> Bool {
        await inferenceGate.isBusy
    }

    func preparationInFlight() async -> Bool {
        await preparationGate.isBusy
    }

    private func ensureManager() async -> SpeechPresenceManager? {
        if let manager { return manager }
        if let managerTask {
            return try? await managerTask.value
        }
        if let retryAfter, now() < retryAfter { return nil }
        guard modelPresent() else { return nil }
        let task = Task { try await loadManager() }
        managerTask = task
        do {
            let manager = try await task.value
            managerTask = nil
            loadFailureCount = 0
            retryAfter = nil
            self.manager = manager
            return manager
        } catch {
            managerTask = nil
            loadFailureCount = min(loadFailureCount + 1, 6)
            let delay = min(loadRetryBaseSeconds * pow(2, Double(loadFailureCount - 1)), 30)
            retryAfter = now().addingTimeInterval(delay)
            Log.audio.error("vad load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func read(samples: [Float]?, url: URL, sampleRate: Int) async -> SpeechPresenceReading {
        let start = Date()

        let samplesPeak = samples.map(Self.peakMagnitude)
        if let samplesPeak, samplesPeak < SpeechPresenceGate.silenceFloor {
            return Self.silentReading(peak: samplesPeak, since: start)
        }

        let audioSeconds = samples.map { Double($0.count) / Double(sampleRate) } ?? Self.fileSeconds(url)
        guard let audioSeconds else {
            return Self.failOpen(.unreadable, peak: 1, audioSeconds: 0, budget: 0, since: start)
        }
        let budget = deadlineSeconds + deadlinePerAudioSecond * audioSeconds

        // In-memory samples were already checked for silence, so preparing them for a model that is still
        // busy buys nothing. A WAV-only take is still decoded: that decode is its silence check.
        if samples != nil, await inferenceGate.isBusy {
            return Self.failOpen(
                .busy, peak: samplesPeak ?? 1, audioSeconds: audioSeconds, budget: budget, since: start)
        }

        let input: [Float]
        let prepareStart = Date()
        do {
            input = try await preparationGate.run(seconds: budget) { [prepareInput] in
                try await prepareInput(samples, url, sampleRate)
            }
        } catch {
            return Self.failOpen(
                Self.skipReason(for: error), peak: samplesPeak ?? 1,
                audioSeconds: audioSeconds, budget: budget, since: start)
        }
        let inferenceBudget = max(0, budget - Date().timeIntervalSince(prepareStart))
        let peak = samplesPeak ?? Self.peakMagnitude(input)
        if peak < SpeechPresenceGate.silenceFloor {
            return Self.silentReading(peak: peak, since: start)
        }

        let manager: SpeechPresenceManager
        switch await loadedManager() {
        case .success(let loaded): manager = loaded
        case .failure(let reason):
            return Self.failOpen(reason, peak: peak, audioSeconds: audioSeconds, budget: budget, since: start)
        }

        let probabilities: [Float]
        do {
            probabilities = try await inferenceGate.run(seconds: inferenceBudget) {
                try await manager.process(input)
            }
        } catch {
            return Self.failOpen(
                Self.skipReason(for: error), peak: peak, audioSeconds: audioSeconds, budget: budget, since: start)
        }

        let verdict = SpeechPresenceGate.evaluate(chunkProbabilities: probabilities, peak: peak)
        return SpeechPresenceReading(
            presence: verdict, peak: peak,
            latencyMs: Self.elapsedMs(since: start), modelUsed: true,
            speechStart: SpeechPresenceGate.speechStart(chunkProbabilities: probabilities),
            chunkProbabilities: probabilities)
    }

    private static func skipReason(for error: any Error) -> SkipReason {
        switch error {
        case is SingleFlightDeadline.Busy: .busy
        case is DeadlineExceeded: .deadline
        case is CancellationError: .cancelled
        default: .failed
        }
    }

    private func loadedManager() async -> Result<SpeechPresenceManager, SkipReason> {
        if let manager { return .success(manager) }
        do {
            let loaded = try await runWithDeadline(seconds: loadDeadlineSeconds) { [self] in
                await ensureManager()
            }
            return loaded.map { .success($0) } ?? .failure(.noModel)
        } catch is DeadlineExceeded {
            return .failure(.loadDeadline)
        } catch {
            return .failure(.cancelled)
        }
    }

    private static func vadInput(samples: [Float]?, url: URL, sampleRate: Int) throws -> [Float] {
        guard let samples else { return try AudioDecoder.pcmMono(url, sampleRate: VadManager.sampleRate) }
        guard sampleRate != VadManager.sampleRate else { return samples }
        return try AudioDecoder.resampleMono(samples, from: sampleRate, to: VadManager.sampleRate)
    }

    private static func fileSeconds(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private static func silentReading(peak: Float, since start: Date) -> SpeechPresenceReading {
        SpeechPresenceReading(
            presence: .noSpeech, peak: peak, latencyMs: elapsedMs(since: start), modelUsed: false)
    }

    private static func failOpen(
        _ reason: SkipReason, peak: Float, audioSeconds: Double, budget: Double, since start: Date
    ) -> SpeechPresenceReading {
        let latencyMs = elapsedMs(since: start)
        let message = "vad skipped, gate open reason=\(reason.rawValue) audio=\(String(format: "%.1f", audioSeconds))s budget=\(Int(budget * 1000))ms after=\(Int(latencyMs))ms"
        if reason == .cancelled {
            Log.audio.debug("\(message, privacy: .public)")
        } else {
            Log.audio.notice("\(message, privacy: .public)")
        }
        return SpeechPresenceReading(presence: .speech, peak: peak, latencyMs: latencyMs, modelUsed: false)
    }

    private static func peakMagnitude(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        return peak
    }

    private static func elapsedMs(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1000
    }
}
