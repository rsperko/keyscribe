import Foundation
import Testing
@testable import KeyScribeApp

struct ParakeetUnifiedEngineTests {
    private func engine() -> ParakeetUnifiedEngine {
        ParakeetUnifiedEngine(modelsDir: URL(fileURLWithPath: "/tmp"))
    }

    @Test func ownsExactlyItsSdkDerivedBundleDir() {
        #expect(engine().installDirNames == ["parakeet-unified-en-0.6b"])
    }

    @Test func installDirNameIsASinglePathComponent() {
        let name = engine().installDirNames[0]
        #expect(!name.contains("/"))
    }

    @Test func partialInstallDoesNotCountAsInstalled() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ks-unified-\(UUID().uuidString)", isDirectory: true)
        let bundle = dir.appendingPathComponent("parakeet-unified-en-0.6b", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let e = ParakeetUnifiedEngine(modelsDir: dir)
        #expect(e.verifyInstalled(in: dir) == false)

        try Data().write(to: bundle.appendingPathComponent("parakeet_unified_encoder_int8.mlmodelc"))
        #expect(e.verifyInstalled(in: dir) == false)
    }

    @Test func advertisesNoBiasAndNoStreaming() {
        let e = engine()
        #expect(e.supportsRecognitionBias == false)
        #expect(e.supportsStreaming == false)
        #expect(e.supportsSampleInput == true)
        #expect(e.captureSampleRate == 16000)
    }

    @Test func registryConstructsTheUnifiedEngine() {
        let built = EngineRegistry.engine("parakeet-unified-en", modelsDir: URL(fileURLWithPath: "/tmp"))
        #expect(built?.id == "parakeet-unified-en")
    }
}
