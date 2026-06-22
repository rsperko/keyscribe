import AppKit
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
        let installPath: String?
    }

    @Published private(set) var rows: [Row] = []
    @Published var pendingDeleteId: String?
    @Published var pendingDeleteLeavesNoEngine = false

    var activeName: String { SpeechModelCatalog.entry(for: set.activeId)?.displayName ?? set.activeId }

    private var set: SpeechModelSet
    private var downloading: [String: ModelLoadProgress] = [:]
    private var verifying: Set<String> = []
    private var verifyFailed: Set<String> = []
    private var verifiedOk: Set<String> = []
    private var errors: [String: String] = [:]
    private var installedSizes: [String: Int64] = [:]

    private let download: (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void
    private let verify: (String) async -> Bool?
    private let evictEngine: (String) async -> Void
    private let onActiveChange: (String) -> Void

    init(
        activeId: String,
        download: @escaping (String, @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> Void,
        verify: @escaping (String) async -> Bool?,
        evictEngine: @escaping (String) async -> Void,
        onActiveChange: @escaping (String) -> Void
    ) {
        self.download = download
        self.verify = verify
        self.evictEngine = evictEngine
        self.onActiveChange = onActiveChange
        set = SpeechModelSet(
            catalog: SpeechModelCatalog.all,
            installed: ModelInstallStore.installedIds(),
            activeId: activeId)
        refreshSizes()
        rebuild()
    }

    func reveal(_ id: String) {
        guard let url = ModelInstallStore.presentInstallURLs(for: id).first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func refreshSizes() {
        var sizes: [String: Int64] = [:]
        for info in SpeechModelCatalog.all where !info.systemManaged && set.isUsable(info.id) {
            sizes[info.id] = ModelInstallStore.installedBytes(for: info.id)
        }
        installedSizes = sizes
    }

    func syncActive(_ id: String) {
        guard set.isUsable(id), set.activeId != id else { return }
        try? set.select(id)
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
                    Task { @MainActor in
                        self.downloading[id] = progress
                        self.rebuild()
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
            ModelInstallStore.removeFiles(for: id)
            ModelInstallStore.markRemoved(id)
            try? set.delete(id)
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
            // A model that can't transcribe the known clip must not stay selectable.
            if SpeechModelCatalog.entry(for: id)?.systemManaged == false {
                let wasActive = set.activeId == id
                ModelInstallStore.markRemoved(id)
                try? set.delete(id)
                if wasActive { onActiveChange(set.activeId) }
            }
        } else {
            // Passed, or skipped because no clip is bundled (dev runs) — treat as installed.
            verifyFailed.remove(id)
            ModelInstallStore.markInstalled(id)
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
            ModelInstallStore.removeFiles(for: id)
            ModelInstallStore.markRemoved(id)
            try? set.delete(id)
            verifyFailed.remove(id)
            if wasActive { onActiveChange(set.activeId) }
            refreshSizes()
            rebuild()
        }
    }

    private func rebuild() {
        rows = SpeechModelCatalog.all.map { info in
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
                installPath: installed ? ModelInstallStore.presentInstallURLs(for: info.id).first?.path : nil)
        }
    }
}
