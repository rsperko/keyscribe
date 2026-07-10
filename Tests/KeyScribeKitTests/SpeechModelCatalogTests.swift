import Testing
@testable import KeyScribeKit

struct SpeechModelCatalogTests {
    @Test func curatedListIsTheKnownEngines() {
        #expect(
            Set(SpeechModelCatalog.all.map(\.id))
                == ["parakeet", "parakeet-tdt-ctc-110m", "whisper", "whisper-small-en", "apple",
                    "qwen3-asr-0.6b", "qwen3-asr-1.7b", "moonshine-base-en"])
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
