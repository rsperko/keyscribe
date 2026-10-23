import Foundation
import Testing
@testable import KeyScribeApp

struct AliasDiscoveryRunnerTests {
    private func file(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-alias-\(UUID().uuidString).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func aMissingInputIsAFailure() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-alias-\(UUID().uuidString)")
        #expect(await !AliasDiscoveryRunner.run(path: missing, only: nil, cohorts: nil, threshold: 0.5))
    }

    @Test func anUnreadableLineIsAFailure() async throws {
        let url = try file("not json\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await !AliasDiscoveryRunner.run(path: url, only: nil, cohorts: nil, threshold: 0.5))
    }

    @Test func transcriptsThatTheCohortFilterLeavesEmptyAreAFailure() async throws {
        let url = try file(#"{"heard": "post grass", "reference": "Postgres", "terms": ["Postgres"], "cohort": "a"}"# + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await !AliasDiscoveryRunner.run(path: url, only: nil, cohorts: ["b"], threshold: 0.5))
    }

    @Test func aManifestRunPassesOnlyWhenEveryEngineEvaluatedEveryRecordingItHad() {
        typealias Run = AliasDiscoveryRunner.EngineRun
        #expect(AliasDiscoveryRunner.passed([Run(loaded: true, records: 3)]))
        #expect(!AliasDiscoveryRunner.passed([]))
        #expect(!AliasDiscoveryRunner.passed([Run(loaded: true, records: 3), Run(loaded: false)]))
        #expect(!AliasDiscoveryRunner.passed([Run(loaded: true, records: 0)]))
        #expect(!AliasDiscoveryRunner.passed([Run(loaded: true, records: 3, transcriptionFailures: 1)]))
    }

    @Test func readableTranscriptsSucceed() async throws {
        let url = try file(#"{"heard": "post grass", "reference": "Postgres", "terms": ["Postgres"]}"# + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await AliasDiscoveryRunner.run(path: url, only: nil, cohorts: nil, threshold: 0.5))
    }
}
