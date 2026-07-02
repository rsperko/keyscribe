import Testing
@testable import KeyScribeKit

private func info(
    _ id: String, system: Bool = false, defaultEnglish: Bool = false,
    supportsRecognitionBias: Bool = true
) -> SpeechModelInfo {
    SpeechModelInfo(
        id: id, kind: .whisper, displayName: id, summary: "", languageCount: 1,
        approxDownloadBytes: system ? 0 : 1, systemManaged: system,
        isDefaultEnglish: defaultEnglish, supportsRecognitionBias: supportsRecognitionBias)
}

private let realCatalog = SpeechModelCatalog.all

struct SpeechModelSetTests {
    // Usability: system-managed always usable; downloadable only when installed.
    @Test func systemManagedAlwaysUsable() {
        let s = SpeechModelSet(catalog: realCatalog, installed: [], activeId: "apple")
        #expect(s.isUsable("apple"))
        #expect(!s.isUsable("parakeet"))
        #expect(!s.isUsable("whisper"))
    }

    @Test func downloadableUsableOnlyWhenInstalled() {
        let s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet"], activeId: "parakeet")
        #expect(s.isUsable("parakeet"))
        #expect(!s.isUsable("whisper"))
    }

    @Test func usableIdsAreCatalogOrdered() {
        let s = SpeechModelSet(catalog: realCatalog, installed: ["whisper"], activeId: "apple")
        #expect(s.usableIds == ["whisper", "apple"])
    }

    // Selection
    @Test func selectUsableSucceeds() throws {
        var s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet"], activeId: "apple")
        try s.select("parakeet")
        #expect(s.activeId == "parakeet")
    }

    @Test func selectNotUsableThrows() {
        var s = SpeechModelSet(catalog: realCatalog, installed: [], activeId: "apple")
        #expect(throws: ModelSelectionError.notUsable("parakeet")) { try s.select("parakeet") }
    }

    @Test func selectUnknownThrows() {
        var s = SpeechModelSet(catalog: realCatalog, installed: [], activeId: "apple")
        #expect(throws: ModelSelectionError.unknown("nope")) { try s.select("nope") }
    }

    // Deletion consequences
    @Test func systemManagedNotDeletable() {
        let s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet"], activeId: "parakeet")
        #expect(s.deletionConsequence("apple") == .notDeletable)
    }

    @Test func notInstalledNothingToDelete() {
        let s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet"], activeId: "parakeet")
        #expect(s.deletionConsequence("whisper") == .notInstalled)
    }

    @Test func deletingInactiveWithOthersUsableIsRoutine() {
        let s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet", "whisper"], activeId: "parakeet")
        #expect(s.deletionConsequence("whisper") == .routine)
    }

    @Test func deletingActiveWithAppleFloorConfirmsActive() {
        // apple is always usable, so deleting the active downloadable never strands the app
        let s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet"], activeId: "parakeet")
        #expect(s.deletionConsequence("parakeet") == .confirmActive)
    }

    @Test func deletingOnlyUsableEngineWarnsNoEngineLeft() {
        // a degenerate catalog with no system-managed floor
        let cat = [info("only", system: false, defaultEnglish: true)]
        let s = SpeechModelSet(catalog: cat, installed: ["only"], activeId: "only")
        #expect(s.deletionConsequence("only") == .confirmLeavesNoUsableEngine)
    }

    // Deletion effects
    @Test func deletingActiveReassignsToDefaultEnglishWhenUsable() {
        var s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet", "whisper"], activeId: "whisper")
        s.delete("whisper")
        #expect(!s.installed.contains("whisper"))
        #expect(s.activeId == "parakeet")   // default-English fallback
    }

    @Test func deletingActiveFallsBackToAppleFloor() {
        var s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet"], activeId: "parakeet")
        s.delete("parakeet")
        #expect(s.activeId == "apple")      // system-managed floor remains usable
    }

    @Test func deletingInactiveLeavesActiveUnchanged() {
        var s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet", "whisper"], activeId: "parakeet")
        s.delete("whisper")
        #expect(s.activeId == "parakeet")
    }

    // Deleting the last usable model must actually remove it from `installed` (into the "no model
    // installed" state the UI narrates) — not desync the set so the row still reads "Installed" and the
    // next dictation silently re-downloads.
    @Test func deletingTheOnlyUsableEngineRemovesItIntoANoUsableState() {
        let cat = [info("only", system: false, defaultEnglish: true)]
        var s = SpeechModelSet(catalog: cat, installed: ["only"], activeId: "only")
        s.delete("only")
        #expect(!s.installed.contains("only"))
        #expect(s.usableIds.isEmpty)
        #expect(!s.isUsable(s.activeId))
    }

    @Test func markInstalledMakesUsable() {
        var s = SpeechModelSet(catalog: realCatalog, installed: [], activeId: "apple")
        s.markInstalled("whisper")
        #expect(s.isUsable("whisper"))
    }
}
