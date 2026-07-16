import Foundation
import Testing
@testable import KeyScribeKit

struct CaptureRetentionTests {
    private func file(_ name: String, mb: Int, minutesAgo: Int) -> CaptureRetention.File {
        CaptureRetention.File(
            name: name,
            bytes: Int64(mb) * 1_048_576,
            modified: Date(timeIntervalSince1970: 1_000_000 - Double(minutesAgo) * 60))
    }

    @Test func emptyDirectoryExpiresNothing() {
        #expect(CaptureRetention.expired(files: [], maxBytes: 1_048_576).isEmpty)
    }

    @Test func everyFileIsKeptWhenTheBudgetCoversThem() {
        let files = [file("a.wav", mb: 2, minutesAgo: 0), file("b.wav", mb: 2, minutesAgo: 5)]
        #expect(CaptureRetention.expired(files: files, maxBytes: 10 * 1_048_576).isEmpty)
    }

    @Test func oldestFilesExpireOnceNewerOnesFillTheBudget() {
        let files = [
            file("newest.wav", mb: 3, minutesAgo: 0),
            file("middle.wav", mb: 3, minutesAgo: 5),
            file("oldest.wav", mb: 3, minutesAgo: 10),
        ]
        #expect(CaptureRetention.expired(files: files, maxBytes: 7 * 1_048_576) == ["oldest.wav"])
    }

    // A single take larger than the whole budget must still be retained — the point of the feature is to
    // have the last recording to inspect. Accumulate-then-cut would delete it and retain nothing.
    @Test func theNewestCaptureIsKeptEvenWhenItAloneExceedsTheBudget() {
        let files = [file("huge.wav", mb: 50, minutesAgo: 0), file("old.wav", mb: 1, minutesAgo: 5)]
        #expect(CaptureRetention.expired(files: files, maxBytes: 10 * 1_048_576) == ["old.wav"])
    }

    @Test func equalTimestampsBreakDeterministicallyByName() {
        let files = [
            file("a.wav", mb: 4, minutesAgo: 0),
            file("b.wav", mb: 4, minutesAgo: 0),
            file("c.wav", mb: 4, minutesAgo: 0),
        ]
        #expect(CaptureRetention.expired(files: files, maxBytes: 9 * 1_048_576) == ["a.wav"])
    }
}
