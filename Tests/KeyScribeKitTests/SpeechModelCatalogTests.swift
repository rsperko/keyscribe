import Testing
@testable import KeyScribeKit

struct SpeechModelCatalogTests {
    @Test func curatedListIsTheKnownEngines() {
        #expect(
            Set(SpeechModelCatalog.all.map(\.id))
                == ["parakeet", "parakeet-unified-en", "parakeet-ultra", "parakeet-tdt-ctc-110m", "whisper",
                    "whisper-small-en", "apple", "qwen3-asr-0.6b", "qwen3-asr-1.7b"])
    }

    @Test func retiredModelsAreNamedButNoLongerOffered() {
        #expect(SpeechModelCatalog.retiredDisplayNames["moonshine-base-en"] == "Moonshine Base (English)")
        for id in SpeechModelCatalog.retiredDisplayNames.keys {
            #expect(SpeechModelCatalog.entry(for: id) == nil)
        }
    }

    @Test func exactlyOneDefaultEnglishEngine() {
        #expect(SpeechModelCatalog.all.filter(\.isDefaultEnglish).count == 1)
        #expect(SpeechModelCatalog.defaultEnglishId == "parakeet-ultra")
        #expect(SpeechModelCatalog.entry(for: "parakeet-ultra")?.isDefaultEnglish == true)
    }

    @Test func appleIsSystemManagedWithNoDownload() {
        let apple = SpeechModelCatalog.entry(for: "apple")
        #expect(apple?.systemManaged == true)
        #expect(apple?.approxDownloadBytes == 0)
        #expect(apple?.kind == .apple)
    }

    @Test func downloadableEnginesAdvertiseASize() {
        for e in SpeechModelCatalog.all where !e.systemManaged {
            #expect(e.approxDownloadBytes > 0)
        }
    }


    @Test func smallEnglishWhisperIsACompactEnglishBiasCapableVariant() {
        let small = SpeechModelCatalog.entry(for: "whisper-small-en")
        #expect(small?.kind == .whisper)
        #expect(small?.languageCount == 1)
        #expect(small?.supportsRecognitionBias == true)
        #expect(small?.isDefaultEnglish == false)
        let turbo = SpeechModelCatalog.entry(for: "whisper")
        #expect((small?.approxDownloadBytes ?? .max) < (turbo?.approxDownloadBytes ?? 0))
    }

    @Test func parakeetUnifiedIsEnglishOnlyAndNotTheDefault() {
        let u = SpeechModelCatalog.entry(for: "parakeet-unified-en")
        #expect(u?.kind == .parakeet)
        #expect(u?.languageCount == 1)
        #expect(u?.isDefaultEnglish == false)
        #expect(u?.supportsRecognitionBias == false)
        #expect((u?.approxDownloadBytes ?? 0) > 0)
        // SpeechModelChoiceCopy.memoryUse maps 0 to "Almost no memory", so an unmeasured 0 would make
        // the picker lie about the largest Parakeet in the list.
        #expect((u?.approxMemoryBytes ?? 0) > 0)
    }

    @Test func parakeetUnifiedSitsInsideTheParakeetFamilyBlock() {
        let ids = SpeechModelCatalog.all.map(\.id)
        let v3 = ids.firstIndex(of: "parakeet")
        let unified = ids.firstIndex(of: "parakeet-unified-en")
        let ctc = ids.firstIndex(of: "parakeet-tdt-ctc-110m")
        #expect(unified == v3.map { $0 + 1 })
        #expect(unified.map { u in ctc.map { u < $0 } } == true)
    }

    @Test func parakeetUltraIsTheRecommendedMultilingualParakeet() {
        let ultra = SpeechModelCatalog.entry(for: "parakeet-ultra")
        let v3 = SpeechModelCatalog.entry(for: "parakeet")
        #expect(ultra?.kind == .parakeet)
        #expect(ultra?.languageCount == v3?.languageCount)
        #expect(ultra?.isDefaultEnglish == true)
        #expect(v3?.isDefaultEnglish == false)
        #expect(ultra?.supportsRecognitionBias == false)
        #expect((ultra?.approxDownloadBytes ?? 0) > 0)
        #expect((ultra?.approxMemoryBytes ?? 0) > 0)
    }

    @Test func recommendedParakeetLeadsTheCatalogAheadOfV3() {
        let ids = SpeechModelCatalog.all.map(\.id)
        #expect(ids.first == SpeechModelCatalog.defaultEnglishId)
        #expect(ids.firstIndex(of: "parakeet") == 1)
    }

    @Test func recommendedModelIsNeitherLegacyNorLower() {
        let recommended = SpeechModelCatalog.entry(for: SpeechModelCatalog.defaultEnglishId)
        #expect(recommended?.isLegacy == false)
        #expect((recommended?.accuracy ?? .lower) > .lower)
    }

    @Test func legacyModelsTrailEveryCurrentModel() {
        let legacy = SpeechModelCatalog.all.enumerated().filter { $0.element.isLegacy }.map(\.offset)
        let current = SpeechModelCatalog.all.enumerated().filter { !$0.element.isLegacy }.map(\.offset)
        #expect(!legacy.isEmpty)
        #expect((current.max() ?? 0) < (legacy.min() ?? .max))
    }

    @Test func compactParakeetIsLegacy() {
        #expect(SpeechModelCatalog.entry(for: "parakeet-tdt-ctc-110m")?.isLegacy == true)
    }

    @Test func appleSpeechIsLabeledLowerSoNoOneMistakesItForTheBest() {
        #expect(SpeechModelCatalog.entry(for: "apple")?.accuracy == .lower)
    }

    @Test func accuracyBucketsOrderFromLowerToTop() {
        #expect(SpeechAccuracy.lower < .good)
        #expect(SpeechAccuracy.good < .high)
        #expect(SpeechAccuracy.high < .top)
    }

    @Test func accuracyIsGradedByPointsBehindTheMostAccurateOfferedModel() {
        #expect(SpeechAccuracy.grade(averageWER: 7.0, best: 7.0) == .top)
        #expect(SpeechAccuracy.grade(averageWER: 8.0, best: 7.0) == .top)
        #expect(SpeechAccuracy.grade(averageWER: 8.1, best: 7.0) == .high)
        #expect(SpeechAccuracy.grade(averageWER: 9.5, best: 7.0) == .high)
        #expect(SpeechAccuracy.grade(averageWER: 9.6, best: 7.0) == .good)
        #expect(SpeechAccuracy.grade(averageWER: 12.0, best: 7.0) == .good)
        #expect(SpeechAccuracy.grade(averageWER: 12.1, best: 7.0) == .lower)
    }

    @Test func speedIsGradedAgainstTheFastestOfferedModel() {
        #expect(SpeechSpeed.grade(realTimeFactor: 0.01, fastest: 0.01) == .fastest)
        #expect(SpeechSpeed.grade(realTimeFactor: 0.02, fastest: 0.01) == .fastest)
        #expect(SpeechSpeed.grade(realTimeFactor: 0.03, fastest: 0.01) == .fast)
        #expect(SpeechSpeed.grade(realTimeFactor: 0.07, fastest: 0.01) == .fast)
        #expect(SpeechSpeed.grade(realTimeFactor: 0.09, fastest: 0.01) == .slower)
    }

    @Test func theMostAccurateOfferedModelIsGradedTop() {
        let offered = SpeechModelCatalog.all.filter { !$0.isLegacy }
        let best = offered.min { $0.averageWER < $1.averageWER }
        #expect(best?.accuracy == .top)
    }

    @Test func theFastestOfferedModelIsGradedFastest() {
        let offered = SpeechModelCatalog.all.filter { !$0.isLegacy }
        let fastest = offered.min { $0.realTimeFactor < $1.realTimeFactor }
        #expect(fastest?.speed == .fastest)
    }

    @Test func aLegacyModelNeverSetsTheBar() {
        let legacyChampion = SpeechModelInfo(
            id: "legacy-best", kind: .parakeet, displayName: "", summary: "", languageCount: 1,
            approxDownloadBytes: 1, systemManaged: false, isDefaultEnglish: false,
            supportsRecognitionBias: false, averageWER: 0.1, realTimeFactor: 0.0001, isLegacy: true)
        let catalog = SpeechModelCatalog.all + [legacyChampion]
        #expect(SpeechModelCatalog.bestAverageWER(in: catalog) == SpeechModelCatalog.bestAverageWER(in: SpeechModelCatalog.all))
        #expect(SpeechModelCatalog.fastestRealTimeFactor(in: catalog)
            == SpeechModelCatalog.fastestRealTimeFactor(in: SpeechModelCatalog.all))
    }

    @Test func languageCountsAreSane() {
        #expect(SpeechModelCatalog.entry(for: "parakeet")?.languageCount == 25)
        #expect(SpeechModelCatalog.entry(for: "whisper")?.languageCount == 99)
    }

    @Test func onlySystemManagedEntriesLeaveLanguageCoverageToMacOS() {
        for info in SpeechModelCatalog.all {
            #expect((info.languageCount == nil) == info.systemManaged, "\(info.id)")
        }
    }

    @Test func unknownEntryIsNil() {
        #expect(SpeechModelCatalog.entry(for: "nope") == nil)
    }

    @Test func recognitionBiasSupportIsPerEngine() {
        // Only Qwen3 (native context) and Whisper (prompt tokens) bias recognition; Parakeet and Apple do
        // not — the dictionary reaches them only through after-transcription recovery.
        let biasCapable: Set<String> = ["qwen3-asr-0.6b", "qwen3-asr-1.7b", "whisper", "whisper-small-en"]
        for e in SpeechModelCatalog.all {
            #expect(e.supportsRecognitionBias == biasCapable.contains(e.id))
        }
    }
}
