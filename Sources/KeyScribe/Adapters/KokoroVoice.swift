import CoreML
import FluidAudio
import Foundation
import KeyScribeKit

enum DependencyLogging {
    static func configure() {
        AppLogger.mirrorsToConsole = false
        AppLogger.minimumLevel = .error
    }
}

struct SpokenAudio: Sendable, Equatable {
    struct Unusable: Error {
        let problem: SpokenAudioCheck.Problem
        let audio: SpokenAudio?
    }

    var wav: Data
    var synthesis: SpokenAttempt.Synthesis?

    static func made(from result: KokoroAneSynthesisResult) throws -> SpokenAudio {
        let problem = SpokenAudioCheck.problem(in: result.samples)
        if problem == .invalidSamples || problem == .empty { throw Unusable(problem: problem ?? .empty, audio: nil) }
        let timings = result.timings
        let stages: [(String, Double)] = [
            ("albert", timings.albert), ("postAlbert", timings.postAlbert), ("alignment", timings.alignment),
            ("prosody", timings.prosody), ("noise", timings.noise), ("vocoder", timings.vocoder), ("tail", timings.tail),
        ]
        let audio = SpokenAudio(
            wav: try AudioWAV.data(from: result.samples, sampleRate: Double(result.sampleRate), normalize: false),
            synthesis: SpokenAttempt.Synthesis(
                normalizedText: result.normalizedText, phonemes: result.phonemes, predictedDurations: result.predictedDurations,
                stageMilliseconds: stages.map { .init(label: $0.0, value: String(format: "%.1f", $0.1)) },
                sampleRate: result.sampleRate, measurements: SpokenAudioCheck.measure(result.samples, sampleRate: result.sampleRate)))
        if let problem { throw Unusable(problem: problem, audio: audio) }
        return audio
    }
}

actor KokoroVoice: VoiceInstalling {
    struct NotInstalled: Error {}

    nonisolated static var route: String { route(KokoroAneComputeUnits.default) }

    nonisolated static func route(_ units: KokoroAneComputeUnits) -> String {
        func place(_ unit: MLComputeUnits) -> String {
            switch unit {
            case .cpuOnly: "CPU"
            case .cpuAndGPU: "CPU and GPU"
            case .cpuAndNeuralEngine: "CPU and Neural Engine"
            case .all: "any"
            @unknown default: "unknown (\(unit.rawValue))"
            }
        }
        return "vocoder on \(place(units.vocoder)), noise on \(place(units.noise)), tail on \(place(units.tail))"
    }

    static let shared = KokoroVoice(
        directory: KeyScribePaths.modelsDir.appendingPathComponent("kokoro-voice", isDirectory: true),
        pronunciationDirectory: {
            (try? TtsCacheDirectory.ensure())?
                .appendingPathComponent(KokoroAneResourceDownloader.modelsSubdirectory)
                .appendingPathComponent(Repo.kokoro.folderName)
        })

    nonisolated let directory: URL
    private nonisolated let pronunciationDirectory: @Sendable () -> URL?
    private nonisolated var marker: URL { directory.appendingPathComponent(".installed") }
    private var loading: Task<KokoroAneManager, any Error>?
    private var evicting: Task<Void, Never>?
    private let speaking = InFlightWork<KokoroAneSynthesisResult>()
    private var removing = false

    init(directory: URL, pronunciationDirectory: @escaping @Sendable () -> URL?) {
        self.directory = directory
        self.pronunciationDirectory = pronunciationDirectory
    }

    nonisolated var isInstalled: Bool { FileManager.default.fileExists(atPath: marker.path) }

    nonisolated var isIntact: Bool {
        guard let pronunciationDirectory = pronunciationDirectory() else { return false }
        let repository = directory.appendingPathComponent(Repo.kokoroAne.folderName)
        let model = ModelNames.KokoroAne.requiredModels.union(SpokenVoices.all.map { "\($0.id).bin" })
        let pronunciation = ModelNames.G2P.requiredModels.union(["us_lexicon_cache.json"])
        return model.allSatisfy { FileManager.default.fileExists(atPath: repository.appendingPathComponent($0).path) }
            && pronunciation.allSatisfy {
                FileManager.default.fileExists(atPath: pronunciationDirectory.appendingPathComponent($0).path)
            }
    }

    func download(progress: @escaping @Sendable (ModelLoadProgress) -> Void) async throws {
        removing = false
        KeyScribePaths.ensureModelsDir()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let phase = "Downloading voice\u{2026}"
        let repository = try await KokoroAneResourceDownloader.ensureModels(variant: .english, directory: directory) { snapshot in
            progress(ModelLoadProgress(phase: phase, fraction: snapshot.fractionCompleted * 0.55))
        }
        let speakers = SpokenVoices.all
        for (index, speaker) in speakers.enumerated() {
            _ = try await KokoroAneResourceDownloader.ensureVoicePack(speaker.id, repoDirectory: repository, variant: .english)
            progress(ModelLoadProgress(phase: phase, fraction: 0.55 + 0.1 * Double(index + 1) / Double(speakers.count)))
        }
        try await KokoroAneResourceDownloader.ensureG2PAssets { snapshot in
            progress(ModelLoadProgress(phase: phase, fraction: 0.65 + snapshot.fractionCompleted * 0.25))
        }
        progress(ModelLoadProgress(phase: "Preparing voice\u{2026}", fraction: 0.9))
        _ = try await loaded()
    }

    func verify() async -> Bool {
        guard !removing,
              let result = try? await speaking.runAlone(waitingUpTo: .seconds(30), {
                  try await self.loaded().synthesizeDetailed(text: SpokenVoices.sample, voice: SpokenVoices.recommended)
              })
        else { return false }
        return result.samples.count > result.sampleRate / 2 && SpokenAudioCheck.problem(in: result.samples) == nil
    }

    nonisolated func setInstalled(_ installed: Bool) throws {
        if installed {
            try Data().write(to: marker)
        } else if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    func remove() async throws {
        removing = true
        await speaking.cancelAndWait()
        await evicting?.value
        let pending = loading
        loading = nil
        if let manager = try? await pending?.value { await manager.cleanup() }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func evict() async {
        let pending = loading
        loading = nil
        let speaking = speaking
        let previous = evicting
        let cleanup = Task {
            await previous?.value
            await speaking.waitUntilFinished()
            if let manager = try? await pending?.value { await manager.cleanup() }
        }
        evicting = cleanup
        await cleanup.value
        if evicting == cleanup { evicting = nil }
    }

    func warm() async {
        await evicting?.value
        guard !removing, isInstalled, isIntact else { return }
        _ = try? await loaded()
    }

    func synthesize(_ text: String, voice: String) async throws -> SpokenAudio {
        guard !removing, isInstalled, isIntact else { throw NotInstalled() }
        let result = try await speaking.runAlone {
            try await self.loaded().synthesizeDetailed(text: text, voice: voice)
        }
        return try SpokenAudio.made(from: result)
    }

    private func loaded() async throws -> KokoroAneManager {
        if let loading { return try await loading.value }
        let directory = directory
        let task = Task {
            let manager = KokoroAneManager(variant: .english, directory: directory)
            try await manager.initialize()
            return manager
        }
        loading = task
        do {
            return try await task.value
        } catch {
            if loading == task { loading = nil }
            throw error
        }
    }
}
