import Testing
@testable import KeyScribeKit

struct SpeechModelCatalogTests {
    @Test func curatedListIsTheKnownEngines() {
        #expect(
            Set(SpeechModelCatalog.all.map(\.id))
                == ["parakeet", "parakeet-unified-en", "parakeet-tdt-ctc-110m", "whisper",
                    "whisper-small-en", "apple", "qwen3-asr-0.6b", "qwen3-asr-1.7b",
                    "moonshine-base-en"])
    }

    @Test func exactlyOneDefaultEnglishEngine() {
        #expect(SpeechModelCatalog.all.filter(\.isDefaultEnglish).count == 1)
        #expect(SpeechModelCatalog.defaultEnglishId == "parakeet")
        #expect(SpeechModelCatalog.entry(for: "parakeet")?.isDefaultEnglish == true)
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
        // Meaningfully smaller than the Large v3 Turbo it sits beside.
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

    // Catalog order IS the UI order and is hand-curated, with no other guard. Keep the Parakeet family
    // contiguous so a later insert can't scatter it.
    @Test func parakeetUnifiedSitsInsideTheParakeetFamilyBlock() {
        let ids = SpeechModelCatalog.all.map(\.id)
        let v3 = ids.firstIndex(of: "parakeet")
        let unified = ids.firstIndex(of: "parakeet-unified-en")
        let ctc = ids.firstIndex(of: "parakeet-tdt-ctc-110m")
        #expect(unified == v3.map { $0 + 1 })
        #expect(unified.map { u in ctc.map { u < $0 } } == true)
    }

    @Test func languageCountsAreSane() {
        #expect(SpeechModelCatalog.entry(for: "parakeet")?.languageCount == 25)
        #expect(SpeechModelCatalog.entry(for: "whisper")?.languageCount == 99)
        #expect((SpeechModelCatalog.entry(for: "apple")?.languageCount ?? 0) > 0)
    }

    @Test func unknownEntryIsNil() {
        #expect(SpeechModelCatalog.entry(for: "nope") == nil)
    }

    @Test func recognitionBiasSupportIsPerEngine() {
        // Only Qwen3 (native context) and Whisper (prompt tokens) bias recognition; Parakeet, Apple, and
        // Moonshine do not — the dictionary reaches them only through after-transcription recovery.
        let biasCapable: Set<String> = ["qwen3-asr-0.6b", "qwen3-asr-1.7b", "whisper", "whisper-small-en"]
        for e in SpeechModelCatalog.all {
            #expect(e.supportsRecognitionBias == biasCapable.contains(e.id))
        }
    }
}
