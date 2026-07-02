import Foundation
import KeyScribeKit

@MainActor
final class SpeechModelsModel: ObservableObject {
    struct Row: Identifiable {
        let info: SpeechModelInfo
        var id: String { info.id }
        let isActive: Bool
        let isUsable: Bool
        let downloadFraction: Double?
        let downloadPhase: String?
        let verifying: Bool
        let verificationFailed: Bool
        let testPassed: Bool
        let errorText: String?
        let installedBytes: Int64?
        let recognitionBiasOn: Bool
        let dictionaryRecoveryOn: Bool
        let dictionaryMatchingRecommended: Bool
    }

    @Published private(set) var rows: [Row] = []
    @Published var pendingDeleteId: String?
    @Published var pendingDeleteLeavesNoEngine = false

    var activeName: String { SpeechModelCatalog.entry(for: set.activeId)?.displayName ?? set.activeId }

    // The selected engine's files are present (or it's system-managed). False means the active model
    // was deleted out from under us and dictation is silently running on a fallback — a problem worth
    // flagging (ui_design.md §6).
    var activeEngineUsable: Bool { self.set.isUsable(self.set.activeId) }

    private var set: SpeechModelSet
    private var downloading: [String: ModelLoadProgress] = [:]
    private var verifying: Set<String> = []
    private var verifyFailed: Set<String> = []
    private var verifiedOk: Set<String> = []
    private var errors: [String: String] = [:]
    private var installedSizes: [String: Int64] = [:]
    private var sizeRefreshGeneration = 0

    private var stt: Settings.STT

    private let download: (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void
    private let verify: (String) async -> Bool?
    private let evictEngine: (String) async -> Void
    private let onActiveChange: (String) -> Void
    private let onDictionaryMatchingChange: (Settings.STT) -> Void
    private let removeFiles: (String) -> Void
    private let markInstalled: (String) -> Void
    private let markRemoved: (String) -> Void
    // Runs `work` immediately when the controller is idle, else parks it until the current dictation
    // finishes. Used so a model delete never removes files an in-flight dictation is about to reload (V4).
    private let deferWhileBusy: (@escaping () -> Void) -> Void

    init(
        activeId: String,
        stt: Settings.STT,
        download: @escaping (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void,
        verify: @escaping (String) async -> Bool?,
        evictEngine: @escaping (String) async -> Void,
        onActiveChange: @escaping (String) -> Void,
        onDictionaryMatchingChange: @escaping (Settings.STT) -> Void,
        deferWhileBusy: @escaping (@escaping () -> Void) -> Void = { $0() },
        initialInstalledIds: Set<String>? = nil,
        removeFiles: @escaping (String) -> Void = { ModelInstallStore.removeFiles(for: $0) },
        markInstalled: @escaping (String) -> Void = { ModelInstallStore.markInstalled($0) },
        markRemoved: @escaping (String) -> Void = { ModelInstallStore.markRemoved($0) }
    ) {
        self.stt = stt
        self.download = download
        self.verify = verify
        self.evictEngine = evictEngine
        self.onActiveChange = onActiveChange
        self.onDictionaryMatchingChange = onDictionaryMatchingChange
        self.deferWhileBusy = deferWhileBusy
        self.removeFiles = removeFiles
        self.markInstalled = markInstalled
        self.markRemoved = markRemoved
        set = SpeechModelSet(
            catalog: EngineRegistry.availableCatalog,
            installed: initialInstalledIds ?? ModelInstallStore.installedIds(),
            activeId: activeId)
        refreshSizes()
        rebuild()
    }

    // Sizing each installed model recursively enumerates its on-disk bundle (many files); doing it
    // synchronously here would block the main actor, including at launch where this model is built.
    // Snapshot the usable ids on the main actor, compute bytes on a utility task, then publish back.
    private func refreshSizes() {
        sizeRefreshGeneration &+= 1
        let generation = sizeRefreshGeneration
        let ids = EngineRegistry.availableCatalog
            .filter { !$0.systemManaged && set.isUsable($0.id) }
            .map(\.id)
        Task.detached(priority: .utility) { [weak self] in
            var sizes: [String: Int64] = [:]
            for id in ids { sizes[id] = ModelInstallStore.installedBytes(for: id) }
            await self?.applySizes(sizes, generation: generation)
        }
    }

    private func applySizes(_ sizes: [String: Int64], generation: Int) {
        guard generation == sizeRefreshGeneration else { return }
        installedSizes = sizes
        rebuild()
    }

    // The first-run flow downloads through the engine directly (not startDownload), so the install
    // store and this model never learned the model is present — it kept reading "not installed" until a
    // redundant re-download in Settings. Mark it installed and refresh so onboarding's download sticks.
    func noteInstalled(_ id: String) {
        markInstalled(id)
        set.markInstalled(id)
        refreshSizes()
        rebuild()
    }

    func syncActive(_ id: String) {
        guard set.isUsable(id), set.activeId != id else { return }
        try? set.select(id)
        rebuild()
    }

    func syncSTT(_ stt: Settings.STT) {
        guard stt != self.stt else { return }
        self.stt = stt
        rebuild()
    }

    func setRecognitionBias(_ on: Bool, for id: String) {
        guard let info = SpeechModelCatalog.entry(for: id) else { return }
        var updated = stt
        updated.setRecognitionBias(on, for: info)
        applySTTUpdate(updated)
    }

    func setDictionaryRecovery(_ on: Bool, for id: String) {
        guard let info = SpeechModelCatalog.entry(for: id) else { return }
        var updated = stt
        updated.setDictionaryRecovery(on, for: info)
        applySTTUpdate(updated)
    }

    func resetDictionaryMatching(for id: String) {
        guard let info = SpeechModelCatalog.entry(for: id) else { return }
        var updated = stt
        updated.resetDictionaryMatching(for: info)
        applySTTUpdate(updated)
    }

    private func applySTTUpdate(_ updated: Settings.STT) {
        guard updated != stt else { return }
        stt = updated
        onDictionaryMatchingChange(updated)
        rebuild()
    }

    func select(_ id: String) {
        guard set.isUsable(id) else { return }
        try? set.select(id)
        onActiveChange(set.activeId)
        rebuild()
    }

    func startDownload(_ id: String) {
        guard downloading[id] == nil, !verifying.contains(id),
            SpeechModelCatalog.entry(for: id)?.systemManaged == false else { return }
        downloading[id] = ModelLoadProgress(phase: "Starting…", fraction: 0)
        errors[id] = nil
        verifyFailed.remove(id)
        rebuild()
        Log.models.notice("download started: \(id, privacy: .public)")
        Task {
            do {
                try await download(id) { progress in
                    // Coalesce: skip the row rebuild unless the phase or whole-percent changed, so a
                    // chatty SDK progress stream does not thrash the install UI.
                    Task { @MainActor in
                        if let last = self.downloading[id], last.phase == progress.phase,
                           Int(last.fraction * 100) == Int(progress.fraction * 100) { return }
                        self.downloading[id] = progress
                        self.updateRow(id)
                    }
                }
            } catch {
                Log.models.error("download failed: \(id, privacy: .public): \(error, privacy: .public)")
                errors[id] = "\(error)"
                downloading[id] = nil
                rebuild()
                return
            }
            Log.models.notice("download complete: \(id, privacy: .public)")
            downloading[id] = nil
            // Record the install marker the instant the bytes are on disk. The self-test below is a
            // full model load + transcribe that can take seconds to minutes; a crash/quit in that
            // window would otherwise leave a complete download that next-launch reconcile could delete
            // as an orphan (Whisper/Qwen now report verifyInstalled, but Moonshine still defers to the
            // marker as its only "installed" signal). A failed self-test un-marks it in runVerification.
            markInstalled(id)
            await runVerification(id, markInstalledOnPass: true)
        }
    }

    // Manually re-run the self-test on an installed engine.
    func test(_ id: String) {
        guard downloading[id] == nil, !verifying.contains(id) else { return }
        Task { await runVerification(id, markInstalledOnPass: false) }
    }

    // Wipe a bad install and download it again (which re-verifies).
    func reinstall(_ id: String) {
        guard SpeechModelCatalog.entry(for: id)?.systemManaged == false else { return }
        let wasActive = set.activeId == id
        Task {
            await evictEngine(id)
            removeFiles(id)
            markRemoved(id)
            set.delete(id)
            verifyFailed.remove(id)
            if wasActive { onActiveChange(set.activeId) }
            rebuild()
            startDownload(id)
        }
    }

    private func runVerification(_ id: String, markInstalledOnPass: Bool) async {
        verifying.insert(id)
        verifiedOk.remove(id)
        errors[id] = nil
        rebuild()
        let result = await verify(id)
        verifying.remove(id)

        if result == false {
            verifyFailed.insert(id)
            errors[id] = "This model failed its self-test — reinstall it."
            // A model that can't transcribe the known clip must not stay selectable — AND its files must be
            // removed, not just un-marked. Un-marking alone leaves a COMPLETE install on disk that the next
            // launch's reconcile re-adopts as Installed (verifyInstalled is true — completeness is not what
            // failed), silently reversing the quarantine (V5). Evict first so the loaded handle is torn down
            // before its files vanish, then delete — making the "reinstall it" message literal and
            // reconcile-proof.
            if SpeechModelCatalog.entry(for: id)?.systemManaged == false {
                let wasActive = set.activeId == id
                await evictEngine(id)
                removeFiles(id)
                markRemoved(id)
                set.delete(id)
                if wasActive { onActiveChange(set.activeId) }
            }
        } else {
            // Passed, or skipped because no clip is bundled (dev runs) — treat as installed.
            verifyFailed.remove(id)
            markInstalled(id)
            set.markInstalled(id)
            // Only a manual re-test of a confirmed pass shows the transient acknowledgement;
            // a fresh install already shows its "Installed" status.
            if result == true && !markInstalledOnPass {
                verifiedOk.insert(id)
                scheduleClearVerified(id)
            }
        }
        refreshSizes()
        rebuild()
    }

    private func scheduleClearVerified(_ id: String) {
        Task {
            try? await Task.sleep(for: .seconds(4))
            verifiedOk.remove(id)
            rebuild()
        }
    }

    func requestDelete(_ id: String) {
        switch set.deletionConsequence(id) {
        case .notDeletable, .notInstalled:
            return
        case .routine:
            performDelete(id)
        case .confirmActive:
            pendingDeleteLeavesNoEngine = false
            pendingDeleteId = id
        case .confirmLeavesNoUsableEngine:
            pendingDeleteLeavesNoEngine = true
            pendingDeleteId = id
        }
    }

    func confirmDelete() {
        guard let id = pendingDeleteId else { return }
        pendingDeleteId = nil
        performDelete(id)
    }

    func cancelDelete() { pendingDeleteId = nil }

    private func performDelete(_ id: String) {
        let wasActive = set.activeId == id
        Task {
            await evictEngine(id)
            // Defer the actual file removal until the controller is idle. Deleting the files mid-dictation
            // would let the in-flight dictation's commit-time reload find the folder gone and re-download
            // the model over the network, mid-dictation (V4). The marker + set updates happen immediately
            // for the UI; the in-flight dictation keeps running on its already-frozen, loaded engine and
            // the files disappear the moment it finishes.
            deferWhileBusy { [removeFiles] in removeFiles(id) }
            markRemoved(id)
            set.delete(id)
            verifyFailed.remove(id)
            if wasActive { onActiveChange(set.activeId) }
            refreshSizes()
            rebuild()
        }
    }

    private func rebuild() {
        rows = EngineRegistry.availableCatalog.map(makeRow)
    }

    // Rebuild only the one row whose state changed (e.g. a download-progress tick) — fires many times
    // per second, so reconstructing every row (and re-statting installed model dirs) each tick was
    // needless churn. SwiftUI's identified ForEach re-renders just the changed row.
    private func updateRow(_ id: String) {
        guard let info = SpeechModelCatalog.all.first(where: { $0.id == id }),
              let index = rows.firstIndex(where: { $0.id == id }) else { rebuild(); return }
        rows[index] = makeRow(info)
    }

    private func makeRow(_ info: SpeechModelInfo) -> Row {
        let installed = !info.systemManaged && set.isUsable(info.id) && downloading[info.id] == nil
        return Row(
            info: info,
            isActive: set.activeId == info.id,
            isUsable: set.isUsable(info.id),
            downloadFraction: downloading[info.id]?.fraction,
            downloadPhase: downloading[info.id]?.phase,
            verifying: verifying.contains(info.id),
            verificationFailed: verifyFailed.contains(info.id),
            testPassed: verifiedOk.contains(info.id),
            errorText: errors[info.id],
            installedBytes: installed ? installedSizes[info.id] : nil,
            recognitionBiasOn: stt.recognitionBiasEnabled(for: info),
            dictionaryRecoveryOn: stt.dictionaryRecoveryEnabled(for: info),
            dictionaryMatchingRecommended: stt.dictionaryMatchingUsesRecommendedSettings(for: info))
    }
}
