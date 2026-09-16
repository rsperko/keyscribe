import Foundation
import Testing
@testable import KeyScribeApp
import KeyScribeKit

struct EngineRegistryLaunchTests {
    private let modelsDir = URL(fileURLWithPath: "/tmp/keyscribe-engine-registry-tests", isDirectory: true)

    @Test func retiredSavedEngineResolvesToAConstructibleEngine() throws {
        let id = EngineRegistry.launchEngineId(saved: "moonshine-base-en", installed: [], failed: [])
        #expect(EngineRegistry.availableCatalog.contains { $0.id == id })
        _ = try SpeechEngineProvider(engines: EngineRegistry.makeAll(modelsDir: modelsDir), activeId: id)
    }

    @Test func knownSavedEngineThatIsNotInstalledIsKept() {
        #expect(EngineRegistry.launchEngineId(saved: "whisper", installed: [], failed: []) == "whisper")
    }

    @Test func retiredSavedEngineMovesToAnInstalledModel() {
        #expect(EngineRegistry.launchEngineId(saved: "moonshine-base-en", installed: ["whisper"], failed: []) == "whisper")
    }

    @Test func defaultEnglishEngineIsConstructibleWithNothingInstalled() throws {
        _ = try SpeechEngineProvider(
            engines: EngineRegistry.makeAll(modelsDir: modelsDir), activeId: SpeechModelCatalog.defaultEnglishId)
    }
}
