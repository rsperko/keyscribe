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
        // completeIds reflects disk reality regardless of the prior marker — a finished download that
        // never got recorded is adopted rather than deleted.
        let plan = ModelMaintenance.reconcile(
            knownIds: known, owned: owned, completeIds: ["whisper"],
            dirsOnDisk: ["whisper"])
        #expect(plan.installed == ["whisper"])
        #expect(plan.removeDirs.isEmpty)
    }

    @Test func dropsAndDeletesIncompleteModel() {
        let plan = ModelMaintenance.reconcile(
            knownIds: known, owned: owned, completeIds: [],
            dirsOnDisk: ["parakeet-tdt-0.6b-v3"])
        #expect(plan.installed.isEmpty)
        #expect(plan.removeDirs == ["parakeet-tdt-0.6b-v3"])
    }

    @Test func preservesUnrecognizedDirs() {
        // The models dir is shared across build variants: a dir this binary doesn't recognize could be a
        // newer build's engine or the other variant's in-flight download, so only dirs owned by a
        // KNOWN-but-incomplete engine are removed.
        let plan = ModelMaintenance.reconcile(
            knownIds: known, owned: owned, completeIds: ["parakeet"],
            dirsOnDisk: ["parakeet-tdt-0.6b-v3", "parakeet-ctc-0.6b-coreml", "some-newer-engine"])
        #expect(plan.removeDirs.isEmpty)
    }

    @Test func protectsRecentlyModifiedDirOfIncompleteEngine() {
        // A partial dir is normally removed, but not while actively written — the other variant may be
        // mid-download into the shared dir.
        let plan = ModelMaintenance.reconcile(
            knownIds: known, owned: owned, completeIds: [],
            dirsOnDisk: ["parakeet-tdt-0.6b-v3"], protectedDirs: ["parakeet-tdt-0.6b-v3"])
        #expect(plan.removeDirs.isEmpty)
    }

    @Test func preservesUnknownMarkerIds() {
        // installed.json is shared: an id this binary doesn't know belongs to the other variant or a
        // newer build, so it must survive the marker rewrite rather than being clobbered.
        let plan = ModelMaintenance.reconcile(
            knownIds: known, owned: owned, completeIds: ["parakeet"],
            dirsOnDisk: ["parakeet-tdt-0.6b-v3", "parakeet-ctc-0.6b-coreml"],
            markedIds: ["parakeet", "future-engine"])
        #expect(plan.installed == ["parakeet", "future-engine"])
    }

    @Test func keepsPartialSecondaryDirOfInstalledEngine() {
        // reconcile only removes owned dirs of a known-but-incomplete engine, so a secondary dir of an
        // installed (complete) engine survives even if partial.
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
