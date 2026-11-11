import Foundation
import KeyScribeKit

protocol VoiceInstalling: AnyObject, Sendable {
    var isInstalled: Bool { get }
    var isIntact: Bool { get }
    func download(progress: @escaping @Sendable (ModelLoadProgress) -> Void) async throws
    func verify() async -> Bool
    func setInstalled(_ installed: Bool) throws
    func remove() async throws
    func synthesize(_ text: String, voice: String) async throws -> SpokenAudio
}

@MainActor
final class SpokenVoiceModel: ObservableObject {
    enum Status: Equatable {
        case notInstalled
        case downloading(phase: String, fraction: Double)
        case testing
        case ready
        case needsAttention
        case removing
    }

    static let approxDownloadBytes: Int64 = 137_000_000

    @Published private(set) var status: Status
    @Published private(set) var error: String?
    @Published var pendingDelete = false
    @Published private(set) var fallbackReason: String?
    @Published private(set) var fallbackEntry: String?
    @Published private(set) var previewFallbackReason: String?
    private var fallbackAttempt: String?
    var fellBack: Bool { fallbackReason != nil }
    var showEntry: ((String) -> Void)?
    var onVoiceUsed: (() -> Void)?

    func replySaved(attempt: String?, entry: String) {
        guard let attempt, attempt == fallbackAttempt else { return }
        fallbackEntry = entry
    }
    private let installer: any VoiceInstalling
    private var speakers: [WeakSpeech] = []

    private struct WeakSpeech {
        weak var speech: NaturalSpeech?
    }

    init(installer: any VoiceInstalling) {
        self.installer = installer
        status = installer.isInstalled ? .ready : .notInstalled
        if installer.isInstalled, !installer.isIntact { markMissing() }
    }

    static let missingFiles = "Some of this voice\u{2019}s files are missing. Reinstall it."

    private func markMissing() {
        Log.models.error("voice files missing")
        status = .needsAttention
        error = Self.missingFiles
    }

    private func resultFailed() {
        guard status == .ready, !installer.isIntact else { return }
        markMissing()
    }

    var isReady: Bool { status == .ready }

    func makeSpeech(
        player: any AudioPlaying = WAVPlayer(), fallback: any SpeechSynthesizing = SystemSpeech(), attempts: SpokenAttempts? = nil,
        preview: Bool = false, details: @escaping @Sendable (Bool) -> [SpokenAttempt.Detail] = SpokenAttempts.environment
    ) -> NaturalSpeech {
        let installer = installer
        let speech = NaturalSpeech(
            ready: { [weak self] in self?.isReady ?? false },
            synthesize: { [weak self] text, voice in
                do {
                    return try await installer.synthesize(text, voice: voice)
                } catch {
                    if !(error is WorkBusy) { await MainActor.run { self?.resultFailed() } }
                    throw error
                }
            },
            player: player, fallback: fallback,
            outcome: { [weak self] natural, reason, attempt in
                guard let self else { return }
                let shown = natural || self.status != .ready ? nil : reason ?? "the natural voice failed"
                guard !preview else {
                    self.previewFallbackReason = shown
                    self.onVoiceUsed?()
                    return
                }
                guard natural || shown != nil else { return }
                self.fallbackReason = shown
                self.fallbackAttempt = shown == nil ? nil : attempt
                self.fallbackEntry = nil
            }, attempts: attempts, details: details)
        speakers = speakers.filter { $0.speech != nil } + [WeakSpeech(speech: speech)]
        return speech
    }

    var canDelete: Bool { status == .ready || status == .needsAttention }

    func download() {
        guard status == .notInstalled else { return }
        install()
    }

    func reinstall() {
        guard status == .needsAttention else { return }
        status = .removing
        error = nil
        Task {
            do {
                try await installer.remove()
            } catch {
                self.status = .needsAttention
                self.error = "Couldn\u{2019}t remove this voice. Try again."
                return
            }
            self.install()
        }
    }

    func requestDelete() {
        guard canDelete else { return }
        pendingDelete = true
    }

    func cancelDelete() {
        pendingDelete = false
    }

    func confirmDelete() {
        guard pendingDelete else { return }
        pendingDelete = false
        for entry in speakers { entry.speech?.stop() }
        status = .removing
        error = nil
        Task {
            do {
                try installer.setInstalled(false)
                try await installer.remove()
            } catch {
                Log.models.error("voice removal failed: \(error, privacy: .public)")
                self.status = installer.isInstalled ? .ready : .needsAttention
                self.error = installer.isInstalled
                    ? "Couldn\u{2019}t remove this voice. Try again."
                    : "Some of this voice\u{2019}s files couldn\u{2019}t be removed. Delete it again, or reinstall it."
                return
            }
            self.status = .notInstalled
        }
    }

    private func install() {
        status = .downloading(phase: "Starting\u{2026}", fraction: 0)
        error = nil
        Log.models.notice("voice download started")
        let installer = installer
        Task {
            do {
                try await installer.download { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading(let phase, let fraction) = self.status else { return }
                        guard phase != progress.phase || Int(fraction * 100) != Int(progress.fraction * 100) else { return }
                        self.status = .downloading(phase: progress.phase, fraction: progress.fraction)
                    }
                }
            } catch {
                Log.models.error("voice download failed: \(error, privacy: .public)")
                let message = "Download failed: \(error.localizedDescription)"
                do {
                    try await installer.remove()
                    self.error = message
                } catch {
                    self.error = "Download failed, and partial voice files couldn\u{2019}t be removed. Try again."
                }
                self.status = .notInstalled
                return
            }
            self.status = .testing
            let verified = await installer.verify()
            self.onVoiceUsed?()
            guard verified else {
                Log.models.error("voice produced no sound")
                self.status = .needsAttention
                self.error = "This voice didn\u{2019}t produce any sound. Reinstall it."
                return
            }
            guard installer.isIntact else {
                self.markMissing()
                return
            }
            do {
                try installer.setInstalled(true)
            } catch {
                self.status = .needsAttention
                self.error = "This voice couldn\u{2019}t be saved as installed. Reinstall it."
                return
            }
            Log.models.notice("voice installed")
            self.status = .ready
        }
    }
}
