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
        let s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet"], activeId: "parakeet")
        #expect(s.deletionConsequence("parakeet") == .confirmActive)
    }

    @Test func deletingOnlyUsableEngineWarnsNoEngineLeft() {
        let cat = [info("only", system: false, defaultEnglish: true)]
        let s = SpeechModelSet(catalog: cat, installed: ["only"], activeId: "only")
        #expect(s.deletionConsequence("only") == .confirmLeavesNoUsableEngine)
    }

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

    @Test func deletingTheOnlyUsableEngineRemovesItIntoANoUsableState() {
        let cat = [info("only", system: false, defaultEnglish: true)]
        var s = SpeechModelSet(catalog: cat, installed: ["only"], activeId: "only")
        s.delete("only")
        #expect(!s.installed.contains("only"))
        #expect(!s.isUsable("only"))
        #expect(!s.isUsable(s.activeId))
    }

    @Test func markInstalledMakesUsable() {
        var s = SpeechModelSet(catalog: realCatalog, installed: [], activeId: "apple")
        s.markInstalled("whisper")
        #expect(s.isUsable("whisper"))
    }

    @Test func failedModelIsNotUsable() {
        let s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet"], activeId: "apple", failed: ["parakeet"])
        #expect(s.installed.contains("parakeet"))
        #expect(!s.isUsable("parakeet"))
        #expect(s.isFailed("parakeet"))
    }

    @Test func failedSystemManagedModelIsNotUsable() {
        let s = SpeechModelSet(catalog: realCatalog, installed: [], activeId: "apple", failed: ["apple"])
        #expect(!s.isUsable("apple"))
    }

    @Test func selectingFailedModelThrows() {
        var s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet"], activeId: "apple", failed: ["parakeet"])
        #expect(throws: ModelSelectionError.notUsable("parakeet")) { try s.select("parakeet") }
    }

    @Test func markFailedActiveHandsOffToUsableEngine() {
        var s = SpeechModelSet(catalog: realCatalog, installed: ["whisper"], activeId: "whisper")
        s.markFailed("whisper")
        #expect(!s.isUsable("whisper"))
        #expect(s.activeId == "apple")   // reassigned to the still-usable system floor
    }

    @Test func markFailedInactiveLeavesActiveUnchanged() {
        var s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet", "whisper"], activeId: "parakeet")
        s.markFailed("whisper")
        #expect(s.activeId == "parakeet")
        #expect(!s.isUsable("whisper"))
    }

    @Test func markFailedOnlyUsableStrandsActive() {
        let cat = [info("only", system: false, defaultEnglish: true)]
        var s = SpeechModelSet(catalog: cat, installed: ["only"], activeId: "only")
        s.markFailed("only")
        #expect(!s.isUsable("only"))
        #expect(!s.isUsable(s.activeId))
    }

    @Test func clearFailedRestoresUsability() {
        var s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet"], activeId: "apple", failed: ["parakeet"])
        s.clearFailed("parakeet")
        #expect(s.isUsable("parakeet"))
        #expect(!s.isFailed("parakeet"))
    }

    @Test func deletingAFailedModelClearsItsFailedFlag() {
        var s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet", "whisper"], activeId: "parakeet", failed: ["whisper"])
        s.delete("whisper")
        #expect(!s.installed.contains("whisper"))
        #expect(!s.isFailed("whisper"))
    }

    @Test func unknownActiveMovesToDefaultEnglishWhenUsable() {
        var s = SpeechModelSet(catalog: realCatalog, installed: ["parakeet", "whisper"], activeId: "retired-model")
        let replaced = s.replaceUnknownActive()
        #expect(replaced)
        #expect(s.activeId == "parakeet")
    }

    @Test func unknownActiveMovesToFirstUsableWhenDefaultIsNotInstalled() {
        var s = SpeechModelSet(catalog: realCatalog, installed: ["whisper"], activeId: "retired-model")
        let replaced = s.replaceUnknownActive()
        #expect(replaced)
        #expect(s.activeId == "whisper")
    }

    @Test func unknownActiveFallsBackToAppleWhenNothingIsInstalled() {
        var s = SpeechModelSet(catalog: realCatalog, installed: [], activeId: "retired-model")
        let replaced = s.replaceUnknownActive()
        #expect(replaced)
        #expect(s.activeId == "apple")
    }

    @Test func unknownActiveWithNothingUsableLandsOnTheDefaultDownload() {
        let withoutApple = realCatalog.filter { !$0.systemManaged }
        var s = SpeechModelSet(catalog: withoutApple, installed: [], activeId: "apple")
        let replaced = s.replaceUnknownActive()
        #expect(replaced)
        #expect(s.activeId == "parakeet")
        #expect(!s.isUsable(s.activeId))
    }

    @Test func knownActiveThatIsNotInstalledKeepsItsSavedValue() {
        var s = SpeechModelSet(catalog: realCatalog, installed: ["whisper"], activeId: "parakeet")
        let replaced = s.replaceUnknownActive()
        #expect(!replaced)
        #expect(s.activeId == "parakeet")
    }

    @Test func unknownActiveSkipsAFailedPreferredReplacement() {
        var s = SpeechModelSet(
            catalog: realCatalog, installed: ["parakeet", "whisper"], activeId: "retired-model", failed: ["parakeet"])
        let replaced = s.replaceUnknownActive()
        #expect(replaced)
        #expect(s.activeId == "whisper")
    }
}
