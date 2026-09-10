import Foundation
import Testing
@testable import KeyScribeApp

struct ParakeetUnifiedEngineTests {
    private func engine() -> ParakeetUnifiedEngine {
        ParakeetUnifiedEngine(modelsDir: URL(fileURLWithPath: "/tmp"))
    }

    // The reap guard. ModelInstallStore.reconcile deletes any directory under models/ that no registered
    // engine claims, so a wrong name here silently removes the whole 613 MB bundle.
    @Test func ownsExactlyItsSdkDerivedBundleDir() {
        #expect(engine().installDirNames == ["parakeet-unified-en-0.6b"])
    }

    // Repo.folderName reaches this name through its `default:` branch (strip "-coreml"), and sibling repos
    // DO return nested paths there (e.g. "kokoro-82m-coreml/ANE"). reconcile compares last path components,
    // so a nested value would match nothing on disk and the bundle would read as an orphan.
    @Test func installDirNameIsASinglePathComponent() {
        let name = engine().installDirNames[0]
        #expect(!name.contains("/"))
    }

    // A half-finished download must read as not-installed: the SDK's own "already downloaded?" probe checks
    // only the encoder, so without this an install that died before vocab.json would look complete forever.
    @Test func partialInstallDoesNotCountAsInstalled() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ks-unified-\(UUID().uuidString)", isDirectory: true)
        let bundle = dir.appendingPathComponent("parakeet-unified-en-0.6b", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let e = ParakeetUnifiedEngine(modelsDir: dir)
        #expect(e.verifyInstalled(in: dir) == false)

        // The encoder alone is exactly the state the SDK's probe would accept.
        try Data().write(to: bundle.appendingPathComponent("parakeet_unified_encoder_int8.mlmodelc"))
        #expect(e.verifyInstalled(in: dir) == false)
    }

    // English-only, no bias path, batch only — the streaming encoders are a separate bundle per latency
    // tier and would need their own silence sweep.
    @Test func advertisesNoBiasAndNoStreaming() {
        let e = engine()
        #expect(e.supportsRecognitionBias == false)
        #expect(e.supportsStreaming == false)
        #expect(e.supportsSampleInput == true)
        #expect(e.captureSampleRate == 16000)
    }

    // Guards the fatalError default in EngineRegistry.construct.
    @Test func registryConstructsTheUnifiedEngine() {
        let built = EngineRegistry.engine("parakeet-unified-en", modelsDir: URL(fileURLWithPath: "/tmp"))
        #expect(built?.id == "parakeet-unified-en")
    }
}
