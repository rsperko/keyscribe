import FluidAudio
import Foundation
import KeyScribeKit

enum DependencyLogging {
    static func configure() {
        AppLogger.mirrorsToConsole = false
        AppLogger.minimumLevel = .error
    }
}

actor KokoroVoice: VoiceInstalling {
    struct NotInstalled: Error {}

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
    private let speaking = InFlightWork<Data>()

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
        guard let result = try? await loaded().synthesizeDetailed(text: SpokenVoices.sample, voice: SpokenVoices.recommended)
        else { return false }
        return result.samples.count > result.sampleRate / 2 && (result.samples.map(abs).max() ?? 0) > 0.01
    }

    nonisolated func setInstalled(_ installed: Bool) throws {
        if installed {
            try Data().write(to: marker)
        } else if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    func remove() async throws {
        await speaking.cancelAndWait()
        let pending = loading
        loading = nil
        if let manager = try? await pending?.value { await manager.cleanup() }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func warm() async {
        guard isInstalled, isIntact else { return }
        _ = try? await loaded()
    }

    func synthesize(_ text: String, voice: String) async throws -> Data {
        guard isInstalled, isIntact else { throw NotInstalled() }
        return try await speaking.run { try await self.loaded().synthesize(text: text, voice: voice) }
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
