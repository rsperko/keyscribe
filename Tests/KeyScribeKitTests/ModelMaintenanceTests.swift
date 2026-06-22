import Testing
@testable import KeyScribeKit

struct ModelMaintenanceTests {
    private let known = ["parakeet", "parakeet-tdt-ctc-110m", "whisper"]
    private let owned: [String: [String]] = [
        "parakeet": ["parakeet-tdt-0.6b-v3", "parakeet-ctc-0.6b-coreml"],
        "parakeet-tdt-ctc-110m": ["parakeet-tdt-ctc-110m", "parakeet-ctc-110m-coreml"],
        "whisper": ["whisper"],
    ]

    @Test func keepsCompleteModelAndItsDirs() {
        let plan = ModelMaintenance.reconcile(
            knownIds: known, owned: owned, completeIds: ["parakeet"],
            dirsOnDisk: ["parakeet-tdt-0.6b-v3", "parakeet-ctc-0.6b-coreml"], keep: ["installed.json"])
        #expect(plan.installed == ["parakeet"])
        #expect(plan.removeDirs.isEmpty)
    }

    @Test func adoptsCompleteButUnmarkedModel() {
        // completeIds reflects disk reality regardless of the prior marker — a finished download
        // that never got recorded is adopted rather than deleted.
        let plan = ModelMaintenance.reconcile(
            knownIds: known, owned: owned, completeIds: ["whisper"],
            dirsOnDisk: ["whisper"])
        #expect(plan.installed == ["whisper"])
        #expect(plan.removeDirs.isEmpty)
    }

    @Test func dropsAndDeletesIncompleteModel() {
        // parakeet partially downloaded (not complete) → not installed, its partial dir removed.
        let plan = ModelMaintenance.reconcile(
            knownIds: known, owned: owned, completeIds: [],
            dirsOnDisk: ["parakeet-tdt-0.6b-v3"])
        #expect(plan.installed.isEmpty)
        #expect(plan.removeDirs == ["parakeet-tdt-0.6b-v3"])
    }

    @Test func removesUnknownOrphanDirs() {
        let plan = ModelMaintenance.reconcile(
            knownIds: known, owned: owned, completeIds: ["parakeet"],
            dirsOnDisk: ["parakeet-tdt-0.6b-v3", "parakeet-ctc-0.6b-coreml", "some-stale-thing"])
        #expect(plan.removeDirs == ["some-stale-thing"])
    }

    @Test func keepsPartialBiasDirOfInstalledEngine() {
        // The CTC bias dir is owned by an installed engine, so it survives reconciliation even if
        // partial — FluidAudio re-downloads it on the next biased dictation.
        let plan = ModelMaintenance.reconcile(
            knownIds: known, owned: owned, completeIds: ["parakeet"],
            dirsOnDisk: ["parakeet-tdt-0.6b-v3", "parakeet-ctc-0.6b-coreml"])
        #expect(plan.removeDirs.isEmpty)
    }

    @Test func protectsKeepEntries() {
        let plan = ModelMaintenance.reconcile(
            knownIds: known, owned: owned, completeIds: [],
            dirsOnDisk: ["installed.json"], keep: ["installed.json"])
        #expect(plan.removeDirs.isEmpty)
    }
}
