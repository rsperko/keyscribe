import Accelerate
import CoreML
import FluidAudio
import Foundation
import KeyScribeKit

struct SpeechPresenceReading: Sendable {
    let presence: SpeechPresence
    let maxProbability: Float
    let peak: Float
    let latencyMs: Double
    let modelUsed: Bool
}

protocol SpeechPresenceDetecting: Sendable {
    func read(samples: [Float]?, url: URL, sampleRate: Int) async -> SpeechPresenceReading
    func prewarm() async
}

extension SpeechPresenceDetecting {
    func prewarm() async {}
}

struct SpeechPresenceManager: Sendable {
    let process: @Sendable ([Float]?, URL, Int) async throws -> [Float]

    init(process: @escaping @Sendable ([Float]?, URL, Int) async throws -> [Float]) {
        self.process = process
    }
}

enum VADModel {
    static let dirName = Repo.vad.folderName

    static func modelURL(in modelsDir: URL) -> URL {
        modelsDir
            .appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile, isDirectory: true)
    }

    static func isPresent(in modelsDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(in: modelsDir).path)
    }

    static func load(
        in modelsDir: URL,
        progressHandler: DownloadUtils.ProgressHandler? = nil
    ) async throws -> MLModel {
        let models = try await DownloadUtils.loadModels(
            .vad, modelNames: [ModelNames.VAD.sileroVadFile],
            directory: modelsDir, progressHandler: progressHandler)
        guard let model = models[ModelNames.VAD.sileroVadFile] else {
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
    private let deadlineSeconds: Double
    private let loadRetryBaseSeconds: Double
    private let now: @Sendable () -> Date
    private let modelPresent: @Sendable () -> Bool
    private let loadManager: @Sendable () async throws -> SpeechPresenceManager
    private let inferenceGate = SingleFlightDeadline()
    private var manager: SpeechPresenceManager?
    private var managerTask: Task<SpeechPresenceManager, Error>?
    private var loadFailureCount = 0
    private var retryAfter: Date?

    init(
        modelsDir: URL,
        deadlineSeconds: Double = 0.25,
        loadRetryBaseSeconds: Double = 1,
        now: @escaping @Sendable () -> Date = { Date() },
        modelPresent: (@Sendable () -> Bool)? = nil,
        loadManager: (@Sendable () async throws -> SpeechPresenceManager)? = nil
    ) {
        self.deadlineSeconds = deadlineSeconds
        self.loadRetryBaseSeconds = loadRetryBaseSeconds
        self.now = now
        self.modelPresent = modelPresent ?? { VADModel.isPresent(in: modelsDir) }
        self.loadManager = loadManager ?? {
            let manager = VadManager(
                config: .default, vadModel: try await VADModel.load(in: modelsDir))
            return SpeechPresenceManager { samples, url, sampleRate in
                let results: [VadResult]
                if sampleRate == VadManager.sampleRate, let samples {
                    results = try await manager.process(samples)
                } else {
                    results = try await manager.process(url)
                }
                return results.map(\.probability)
            }
        }
    }

    func prewarm() async {
        _ = await ensureManager()
    }

    func inferenceInFlight() async -> Bool {
        await inferenceGate.isBusy
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
        let peak = samples.map(Self.peakMagnitude)

        if let peak, peak < SpeechPresenceGate.silenceFloor {
            return SpeechPresenceReading(
                presence: .noSpeech, maxProbability: 0, peak: peak,
                latencyMs: Self.elapsedMs(since: start), modelUsed: false)
        }

        let probabilities: [Float]?
        do {
            probabilities = try await inferenceGate.run(seconds: deadlineSeconds) { [self] () async throws -> [Float]? in
                guard let manager = await ensureManager() else { return nil }
                return try await manager.process(samples, url, sampleRate)
            }
        } catch {
            probabilities = nil
        }

        guard let probabilities else {
            return SpeechPresenceReading(
                presence: .speech, maxProbability: 0, peak: peak ?? 1,
                latencyMs: Self.elapsedMs(since: start), modelUsed: false)
        }

        let verdict = SpeechPresenceGate.evaluate(
            chunkProbabilities: probabilities, peak: peak ?? 1)
        return SpeechPresenceReading(
            presence: verdict, maxProbability: probabilities.max() ?? 0, peak: peak ?? 1,
            latencyMs: Self.elapsedMs(since: start), modelUsed: true)
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
