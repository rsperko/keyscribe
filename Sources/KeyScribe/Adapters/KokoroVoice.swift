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
    var samples: [Float] = []
    var sampleRate = 0

    static func stages(_ result: KokoroAneSynthesisResult) -> [SpokenAttempt.Detail] {
        let timings = result.timings
        let stages: [(String, Double)] = [
            ("albert", timings.albert), ("postAlbert", timings.postAlbert), ("alignment", timings.alignment),
            ("prosody", timings.prosody), ("noise", timings.noise), ("vocoder", timings.vocoder), ("tail", timings.tail),
        ]
        return stages.map { .init(label: $0.0, value: String(format: "%.1f", $0.1)) }
    }

    static func made(from result: KokoroAneSynthesisResult) throws -> SpokenAudio {
        try made(from: result, problem: SpokenAudioCheck.problem(in: result.samples), conditions: nil)
    }

    static func made(
        from result: KokoroAneSynthesisResult, problem: SpokenAudioCheck.Problem?, conditions: RenderConditions?
    ) throws -> SpokenAudio {
        if problem == .invalidSamples || problem == .empty { throw Unusable(problem: problem ?? .empty, audio: nil) }
        let audio = SpokenAudio(
            wav: try AudioWAV.data(from: result.samples, sampleRate: Double(result.sampleRate), normalize: false),
            synthesis: SpokenAttempt.Synthesis(
                normalizedText: result.normalizedText, phonemes: result.phonemes, predictedDurations: result.predictedDurations,
                stageMilliseconds: stages(result), sampleRate: result.sampleRate,
                measurements: SpokenAudioCheck.measure(result.samples, sampleRate: result.sampleRate), conditions: conditions),
            samples: result.samples, sampleRate: result.sampleRate)
        if let problem { throw Unusable(problem: problem, audio: audio) }
        return audio
    }

    static func wav(_ sentences: [[Float]], sampleRate: Int) -> Data? {
        try? AudioWAV.data(from: sentences.flatMap { $0 }, sampleRate: Double(sampleRate), normalize: false)
    }

    static func joined(_ parts: [SpokenAudio]) -> SpokenAudio? {
        guard let first = parts.first else { return nil }
        guard parts.count > 1 else { return first }
        let samples = parts.flatMap(\.samples)
        guard let wav = try? AudioWAV.data(from: samples, sampleRate: Double(first.sampleRate), normalize: false) else { return nil }
        return SpokenAudio(wav: wav, synthesis: first.synthesis, samples: samples, sampleRate: first.sampleRate)
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
    private var loadedAt: Date?
    private var rendersSinceLoad = 0
    private var baseline: SynthesisBaseline?
    private var baselineSavedAt: Date?
    private var baselineUnsaved = false
    private let baselineStore: SynthesisBaselineStore

    init(
        directory: URL, pronunciationDirectory: @escaping @Sendable () -> URL?,
        baselineStore: SynthesisBaselineStore = SynthesisBaselineStore(
            file: KeyScribePaths.supportDir.appendingPathComponent("spoken-voice/baseline.json"))
    ) {
        self.directory = directory
        self.pronunciationDirectory = pronunciationDirectory
        self.baselineStore = baselineStore
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
        loadedAt = nil
        saveBaseline()
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
        let started = Date()
        let result = try await speaking.runAlone { try await self.loaded().synthesizeDetailed(text: text, voice: voice) }
        let problem = SpokenAudioCheck.problem(in: result.samples)
        return try SpokenAudio.made(from: result, problem: problem, conditions: conditions(for: result, healthy: problem == nil, from: started))
    }

    private func conditions(for result: KokoroAneSynthesisResult, healthy: Bool, from started: Date) -> RenderConditions {
        let now = Date()
        rendersSinceLoad += 1
        let stages = SpokenAudio.stages(result)
        let seconds = result.sampleRate > 0 ? Double(result.samples.count) / Double(result.sampleRate) : 0
        let baseline = baseline ?? baselineStore.load()
        let compared = baseline.compare(stages, audioSeconds: seconds)
        self.baseline = baseline
        if healthy {
            self.baseline?.record(stages, audioSeconds: seconds)
            baselineUnsaved = true
            if baselineSavedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true { saveBaseline() }
        }
        return RenderConditions(
            appUptime: SystemConditions.appUptime, voiceUptime: loadedAt.map { now.timeIntervalSince($0) },
            rendersSinceLoad: rendersSinceLoad, during: HardwareActivity.overlaps(from: started, to: now),
            thermal: SystemConditions.thermalState, memoryPressure: SystemConditions.memoryPressure,
            appMemoryMB: SystemConditions.appMemoryMB, loadAverage: SystemConditions.loadAverage, stages: compared)
    }

    private func saveBaseline() {
        guard baselineUnsaved, let baseline else { return }
        baselineUnsaved = false
        baselineSavedAt = Date()
        try? baselineStore.save(baseline)
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
            let manager = try await task.value
            if loadedAt == nil, loading == task {
                loadedAt = Date()
                rendersSinceLoad = 0
            }
            return manager
        } catch {
            if loading == task { loading = nil }
            throw error
        }
    }
}
