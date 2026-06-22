import Foundation
import Testing
@testable import KeyScribeKit

private struct FakeEngine: SpeechEngine {
    let id: String
    var displayName: String { id }
    let supportsRecognitionBias = true
    func loadIfNeeded() async throws {}
    func transcribe(wavURL: URL, biasTerms: [String]) async throws -> String { "" }
    func evict() async {}
}

struct SpeechEngineProviderTests {
    @Test func resolvesActiveEngine() throws {
        let p = try SpeechEngineProvider(
            engines: [FakeEngine(id: "parakeet"), FakeEngine(id: "whisper")],
            activeId: "parakeet")
        #expect(p.active.id == "parakeet")
    }

    @Test func unknownActiveIdThrows() {
        #expect(throws: SpeechEngineError.unknownEngine("nope")) {
            try SpeechEngineProvider(engines: [FakeEngine(id: "parakeet")], activeId: "nope")
        }
    }

    @Test func setActiveSwitchesSingleEngine() throws {
        let p = try SpeechEngineProvider(
            engines: [FakeEngine(id: "parakeet"), FakeEngine(id: "whisper")],
            activeId: "parakeet")
        try p.setActive("whisper")
        #expect(p.active.id == "whisper")
    }

    @Test func setActiveUnknownThrows() throws {
        let p = try SpeechEngineProvider(engines: [FakeEngine(id: "parakeet")], activeId: "parakeet")
        #expect(throws: SpeechEngineError.unknownEngine("apple")) { try p.setActive("apple") }
    }

    @Test func emptyRegistryThrows() {
        #expect(throws: SpeechEngineError.unknownEngine("parakeet")) {
            try SpeechEngineProvider(engines: [], activeId: "parakeet")
        }
    }
}
