import Testing
@testable import KeyScribeKit

struct ModelLoadDiagnosticsTests {
    @Test func lineCarriesTimestampEngineAndError() {
        let line = ModelLoadDiagnostics.line(
            timestamp: "2026-06-30T16:31:00Z", engineId: "parakeet-tdt-ctc-110m",
            timedOut: false, error: "CoreML compile failed")
        #expect(line.contains("2026-06-30T16:31:00Z"))
        #expect(line.contains("parakeet-tdt-ctc-110m"))
        #expect(line.contains("CoreML compile failed"))
        #expect(line.contains("error"))
    }

    @Test func timeoutIsDistinguishedFromError() {
        let line = ModelLoadDiagnostics.line(
            timestamp: "t", engineId: "e", timedOut: true, error: "x")
        #expect(line.contains("timeout"))
        #expect(!line.contains("error"))
    }

    @Test func errorNewlinesAreFlattenedToKeepOneLinePerEntry() {
        let line = ModelLoadDiagnostics.line(
            timestamp: "t", engineId: "e", timedOut: false, error: "first\nsecond")
        #expect(!line.contains("\n"))
        #expect(line.contains("first second"))
    }

    @Test func appendAddsTrailingNewlineToEmptyFile() {
        let out = ModelLoadDiagnostics.appended(existing: "", line: "a", maxEntries: 50)
        #expect(out == "a\n")
    }

    @Test func appendPreservesOrderOldestFirst() {
        let one = ModelLoadDiagnostics.appended(existing: "", line: "a", maxEntries: 50)
        let two = ModelLoadDiagnostics.appended(existing: one, line: "b", maxEntries: 50)
        #expect(two == "a\nb\n")
    }

    @Test func appendTrimsOldestBeyondCap() {
        let out = ModelLoadDiagnostics.appended(existing: "a\nb\nc\n", line: "d", maxEntries: 3)
        #expect(out == "b\nc\nd\n")
    }
}
