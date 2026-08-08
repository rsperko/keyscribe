import Foundation
import Testing
@testable import KeyScribeKit

struct BenchmarkManifestTests {
    private func load(_ json: String) throws -> BenchmarkManifest {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try BenchmarkManifest.load(from: url)
    }

    @Test func decodesVadPresenceExpectation() throws {
        let m = try load("""
        {"schemaVersion":1,"clips":[
          {"id":"a","text":"","checks":{"vad":{"presence":"noSpeech"}}},
          {"id":"b","text":"Yes.","checks":{"vad":{"presence":"speech"}}}
        ]}
        """)
        #expect(m.entries[0].expectedPresence == .noSpeech)
        #expect(m.entries[1].expectedPresence == .speech)
    }

    @Test func absentPresenceIsNoExpectation() throws {
        let m = try load("""
        {"schemaVersion":1,"clips":[
          {"id":"a","text":"hi"},
          {"id":"b","text":"hi","checks":{"stt":{"biasTerms":["Redis"]}}}
        ]}
        """)
        #expect(m.entries.allSatisfy { $0.expectedPresence == nil })
        #expect(m.entries[1].biasTerms == ["Redis"])
    }

    @Test func unknownPresenceValueFailsDecodingRatherThanDroppingTheAssertion() {
        #expect(throws: BenchmarkManifest.InvalidPresence(clip: "c", value: "maybe")) {
            try load("""
            {"schemaVersion":1,"clips":[
              {"id":"c","text":"hi","checks":{"vad":{"presence":"maybe"}}}
            ]}
            """)
        }
    }

    @Test func misspelledPresenceValueFailsDecoding() {
        #expect(throws: BenchmarkManifest.InvalidPresence.self) {
            try load("""
            {"schemaVersion":1,"clips":[
              {"id":"d","text":"","checks":{"vad":{"presence":"nospeech"}}}
            ]}
            """)
        }
    }

    @Test func fileDefaultsToIdDotWav() throws {
        let m = try load("""
        {"schemaVersion":1,"clips":[
          {"id":"a","text":"hi"},
          {"id":"b","file":"custom.wav","text":"hi"}
        ]}
        """)
        #expect(m.entries[0].file == "a.wav")
        #expect(m.entries[1].file == "custom.wav")
    }
}
