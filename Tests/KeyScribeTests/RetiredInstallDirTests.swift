import Foundation
import Testing
@testable import KeyScribeApp

struct RetiredInstallDirTests {
    private let modelsDir = URL(fileURLWithPath: "/tmp", isDirectory: true)

    @Test func reclaimsRetiredModelDirs() {
        let names = ModelInstallStore.retiredInstallDirNames
        #expect(names.contains("parakeet-ctc-0.6b-coreml"))
        #expect(names.contains("moonshine-base-en"))
    }

    @Test func noLiveEngineOwnsARetiredDir() {
        let owned = EngineRegistry.availableCatalog
            .compactMap { EngineRegistry.engine($0.id, modelsDir: modelsDir) }
            .flatMap(\.installDirNames)
        #expect(Set(owned).isDisjoint(with: ModelInstallStore.retiredInstallDirNames))
    }

    @Test func the110mEngineOwnsItsCtcHeadDir() {
        let engine = ParakeetEngine(profile: .tdtCtc110m, modelsDir: modelsDir)
        #expect(engine.installDirNames.contains("parakeet-tdt-ctc-110m"))
        #expect(engine.installDirNames.contains("parakeet-ctc-110m-coreml"))
    }

    @Test func v3EngineOwnsOnlyItsTdtBundle() {
        let engine = ParakeetEngine(profile: .tdtV3, modelsDir: modelsDir)
        #expect(engine.installDirNames == ["parakeet-tdt-0.6b-v3"])
    }
}
