import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct ClaudeTranscriptTitlesTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_000) }

    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ks-transcripts-\(UUID().uuidString)")
    private let entry = ClaudeRegistryEntry(pid: 1, sessionId: "s1", cwd: "/src/keyscribe", name: nil, status: "idle", waitingFor: nil)

    private func write(_ lines: [String], folder: String = "-src-keyscribe", modified: Date) throws {
        let folderURL = dir.appendingPathComponent("projects/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let file = folderURL.appendingPathComponent("s1.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    private func title(_ text: String) -> String { #"{"type":"ai-title","aiTitle":"\#(text)","sessionId":"s1"}"# }

    @Test func cachedTitlesKeepTheExplicitNameSeparateFromGeneratedText() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try write([
            #"{"type":"custom-title","customTitle":"Fix authentication retries","sessionId":"s1"}"#,
            title("Generated summary"),
        ], modified: Date())
        let titles = ClaudeTranscriptTitles(configDirs: [dir]).titles(for: entry)
        #expect(titles.explicitName == "Fix authentication retries")
        #expect(titles.generatedTitle == "Generated summary")
    }

    @Test func aSessionsTranscriptGivesItsTitleAndIsRereadOnlyWhenItChangesAndNotTooOften() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let titles = ClaudeTranscriptTitles(configDirs: [dir], now: { clock.now })
        try write([title("First")], modified: clock.now)
        #expect(titles.title(for: entry) == "First")

        clock.now += 2
        try write([title("First"), title("Second")], modified: clock.now)
        #expect(titles.title(for: entry) == "First")
        clock.now += ClaudeTranscriptTitles.rereadInterval
        #expect(titles.title(for: entry) == "Second")
    }

    @Test func aRoutineCheckUsesWhatWasReadAndLooksOnlyForSessionsNeverSeen() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let titles = ClaudeTranscriptTitles(configDirs: [dir], now: { clock.now })
        let other = ClaudeRegistryEntry(pid: 2, sessionId: "s2", cwd: "/src/keyscribe", name: nil, status: "idle", waitingFor: nil)
        #expect(titles.titles(for: other, rereading: false) == .init())
        try write([title("First")], modified: clock.now)
        #expect(titles.titles(for: entry, rereading: false).generatedTitle == "First")

        clock.now += ClaudeTranscriptTitles.rereadInterval
        try write([title("First"), title("Second")], modified: clock.now)
        #expect(titles.titles(for: entry, rereading: false).generatedTitle == "First")
        #expect(titles.titles(for: entry).generatedTitle == "Second")
    }

    @Test func aTranscriptInAFolderNamedOtherwiseIsStillFound() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try write([title("Found")], folder: "-src-keyscribe-shortened-1a2b", modified: Date())
        #expect(ClaudeTranscriptTitles(configDirs: [dir]).title(for: entry) == "Found")
    }

    @Test func aMissingTranscriptIsLookedForAgainOnlyAfterAWhile() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let titles = ClaudeTranscriptTitles(configDirs: [dir], now: { clock.now })
        #expect(titles.title(for: entry) == nil)
        try write([title("Late")], modified: clock.now)
        #expect(titles.title(for: entry) == nil)
        clock.now += ClaudeTranscriptTitles.rereadInterval
        #expect(titles.title(for: entry) == "Late")
    }

    @Test func onlyTheTailOfALongTranscriptIsRead() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let filler = #"{"type":"assistant","text":"\#(String(repeating: "x", count: ClaudeTranscriptTitles.tailBytes))"}"#
        try write([title("Too early"), filler, title("Recent")], modified: Date())
        #expect(ClaudeTranscriptTitles(configDirs: [dir]).title(for: entry) == "Recent")
        try write([title("Too early"), filler], modified: Date().addingTimeInterval(60))
        #expect(ClaudeTranscriptTitles(configDirs: [dir]).title(for: entry) == nil)
    }
}
