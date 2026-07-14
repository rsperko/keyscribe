import Foundation
import Testing
@testable import KeyScribeKit

struct TextFingerprintTests {
    // Canonical FNV-1a 64-bit test vectors.
    @Test func knownFNV1aVectors() {
        #expect(TextFingerprint.of("").hash == 0xcbf29ce484222325)
        #expect(TextFingerprint.of("a").hash == 0xaf63dc4c8601ec8c)
        #expect(TextFingerprint.of("foobar").hash == 0x85944171f73967e8)
    }

    @Test func countsCharsBytesNewlinesTabs() {
        let fp = TextFingerprint.of("a\tb\nc")
        #expect(fp.chars == 5)
        #expect(fp.bytes == 5)
        #expect(fp.tabs == 1)
        #expect(fp.newlines == 1)
    }

    // chars vs bytes diverging is how the fingerprint catches encoding mangling without logging text.
    @Test func multibyteCharsDifferFromBytes() {
        let fp = TextFingerprint.of("é")
        #expect(fp.chars == 1)
        #expect(fp.bytes == 2)
    }

    @Test func whitespaceChangeChangesHash() {
        #expect(TextFingerprint.of("hello world").hash != TextFingerprint.of("hello  world").hash)
    }

    @Test func hexIsZeroPadded16() {
        #expect(TextFingerprint.of("").hex == "cbf29ce484222325")
        #expect(TextFingerprint.of("").hex.count == 16)
    }
}

struct DictationRecordTests {
    private func sampleRecord() -> DictationRecord {
        var r = DictationRecord(modeName: "Polished Email")
        r.stageMillis[.drain] = 12
        r.stageMillis[.transcribe] = 80
        r.stageMillis[.localProcess] = 1
        r.stageMillis[.rewrite] = 420
        r.stageMillis[.insert] = 30
        r.fingerprints[.raw] = TextFingerprint.of("hello world")
        r.fingerprints[.sentToLLM] = TextFingerprint.of("hello ⟦S1:…⟧")
        r.fingerprints[.final] = TextFingerprint.of("Hello, world.")
        r.audioSeconds = 2.0
        r.cloudInvolved = true
        r.redaction = true
        r.issuedTokenCount = 1
        r.connection = "fast"
        r.model = "gemini-3.1-flash-lite"
        r.targetBundleId = "com.apple.mail"
        r.outcome = .inserted
        return r
    }

    @Test func rtfIsTranscribeSecondsOverAudioSeconds() {
        var r = DictationRecord(modeName: "M")
        r.stageMillis[.transcribe] = 80
        r.audioSeconds = 2.0
        #expect(r.rtf == 0.04)
    }

    @Test func rtfNilWithoutAudioOrTranscribe() {
        var r = DictationRecord(modeName: "M")
        #expect(r.rtf == nil)
        r.audioSeconds = 0
        r.stageMillis[.transcribe] = 80
        #expect(r.rtf == nil)
    }

    // humanSummary substitutes for the unreliable logger, so it must NEVER leak transcript text.
    @Test func humanSummaryContainsNoTranscriptText() {
        let r = sampleRecord()
        let summary = r.humanSummary()
        #expect(!summary.contains("hello"))
        #expect(!summary.contains("world"))
        #expect(!summary.contains("Hello"))
        #expect(!summary.contains("⟦"))
    }

    @Test func humanSummaryReportsHashesTimingsAndMetadata() {
        let r = sampleRecord()
        let summary = r.humanSummary()
        #expect(summary.contains("Polished Email"))
        #expect(summary.contains("inserted"))
        #expect(summary.contains("transcribe 80ms"))
        #expect(summary.contains("rewrite 420ms"))
        #expect(summary.contains(TextFingerprint.of("hello world").hex.prefix(8)))
        #expect(summary.contains("tokens=1"))
        #expect(summary.contains("fast"))
    }

    @Test func humanSummaryIncludesFallbackReasonAndError() {
        var r = DictationRecord(modeName: "M")
        r.outcome = .copied
        r.fallbackReason = "focusChanged"
        #expect(r.humanSummary().contains("focusChanged"))
        var e = DictationRecord(modeName: "M")
        e.outcome = .failed
        e.error = "Transcription timed out"
        #expect(e.humanSummary().contains("Transcription timed out"))
    }

    @Test func recordRoundTripsThroughCodable() throws {
        let r = sampleRecord()
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(DictationRecord.self, from: data)
        #expect(back == r)
    }
}
