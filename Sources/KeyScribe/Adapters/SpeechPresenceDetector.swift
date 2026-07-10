import Accelerate
import CoreML
import FluidAudio
import Foundation
import KeyScribeKit

struct SpeechPresenceReading: Sendable {
    let presence: SpeechPresence
    let maxProbability: Float
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
    private let modelsDir: URL
    private let deadlineSeconds: Double
    private var manager: VadManager?
    private var loadFailed = false

    init(modelsDir: URL, deadlineSeconds: Double = 0.25) {
        self.modelsDir = modelsDir
        self.deadlineSeconds = deadlineSeconds
    }

    func prewarm() async {
        _ = await ensureManager()
    }

    private func ensureManager() async -> VadManager? {
        if let manager { return manager }
        if loadFailed { return nil }
        guard VADModel.isPresent(in: modelsDir) else { return nil }
        do {
            let model = try await VADModel.load(in: modelsDir)
            let manager = VadManager(config: .default, vadModel: model)
            self.manager = manager
            return manager
        } catch {
            loadFailed = true
            Log.audio.error("vad load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func read(samples: [Float]?, url: URL, sampleRate: Int) async -> SpeechPresenceReading {
        let start = Date()
        let peak = samples.map(Self.peakMagnitude)

        if let peak, peak < SpeechPresenceGate.silenceFloor {
            return SpeechPresenceReading(
                presence: .noSpeech, maxProbability: 0,
                latencyMs: Self.elapsedMs(since: start), modelUsed: false)
        }

        let probabilities: [Float]?
        do {
            probabilities = try await runWithDeadline(seconds: deadlineSeconds) { [self] () async throws -> [Float]? in
                guard let manager = await ensureManager() else { return nil }
                let results: [VadResult]
                if sampleRate == VadManager.sampleRate, let samples {
                    results = try await manager.process(samples)
                } else {
                    results = try await manager.process(url)
                }
                return results.map(\.probability)
            }
        } catch {
            probabilities = nil
        }

        guard let probabilities else {
            return SpeechPresenceReading(
                presence: .speech, maxProbability: 0,
                latencyMs: Self.elapsedMs(since: start), modelUsed: false)
        }

        let verdict = SpeechPresenceGate.evaluate(
            chunkProbabilities: probabilities, peak: peak ?? 1)
        return SpeechPresenceReading(
            presence: verdict, maxProbability: probabilities.max() ?? 0,
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
