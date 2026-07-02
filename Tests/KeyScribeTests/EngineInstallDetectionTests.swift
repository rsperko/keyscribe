import XCTest
import AudioCommon
@testable import KeyScribe
import KeyScribeKit

// Guards the on-disk install detection that both reconcile (adopt a completed-but-unmarked model
// instead of deleting it) and the offline cold-load gate (load with zero network when installed)
// depend on. Whisper detects its CoreML bundles; Qwen detects its safetensors weights.
final class EngineInstallDetectionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keyscribe-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private static let whisperBundles = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    private func variantDir(_ installDir: String, _ variant: String) -> URL {
        dir.appendingPathComponent("\(installDir)/models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
    }

    private func writeBundles(_ names: [String], into folder: URL) throws {
        for name in names {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
                withIntermediateDirectories: true)
        }
    }

    func testWhisperUnverifiedWhenAbsent() {
        let engine = WhisperEngine(profile: .largeV3Turbo, modelsDir: dir)
        XCTAssertEqual(engine.verifyInstalled(in: dir), false)
    }

    func testWhisperVerifiedWhenAllRequiredBundlesPresent() throws {
        try writeBundles(Self.whisperBundles,
            into: variantDir("whisper", "openai_whisper-large-v3-v20240930_turbo_632MB"))
        XCTAssertEqual(WhisperEngine(profile: .largeV3Turbo, modelsDir: dir).verifyInstalled(in: dir), true)
    }

    // An interrupted download that landed only one bundle must NOT be adopted as installed.
    func testWhisperUnverifiedWhenCacheIsPartial() throws {
        try writeBundles(["AudioEncoder"],
            into: variantDir("whisper", "openai_whisper-large-v3-v20240930_turbo_632MB"))
        XCTAssertEqual(WhisperEngine(profile: .largeV3Turbo, modelsDir: dir).verifyInstalled(in: dir), false)
    }

    func testWhisperVariantsAreIsolated() throws {
        // Small.en install must not make the turbo model look installed (each owns its own subdir).
        try writeBundles(Self.whisperBundles, into: variantDir("whisper-small-en", "openai_whisper-small.en_217MB"))
        XCTAssertEqual(WhisperEngine(profile: .smallEnglish, modelsDir: dir).verifyInstalled(in: dir), true)
        XCTAssertEqual(WhisperEngine(profile: .largeV3Turbo, modelsDir: dir).verifyInstalled(in: dir), false)
    }

    func testQwenUnverifiedWhenAbsent() {
        let engine = Qwen3ASREngine(profile: .large, modelsDir: dir)
        XCTAssertEqual(engine.verifyInstalled(in: dir), false)
    }

    private func writeFiles(_ names: [String], into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names { try Data().write(to: folder.appendingPathComponent(name)) }
    }

    private func qwenCacheDir(profile: Qwen3ModelProfile) throws -> URL {
        return try HuggingFaceDownloader.getCacheDirectory(
            for: profile.modelId, basePath: dir.appendingPathComponent(profile.subdir, isDirectory: true))
    }

    func testQwenVerifiedWhenFullInstallPresent() throws {
        let cacheDir = try qwenCacheDir(profile: .large)
        try writeFiles(
            ["model.safetensors", "config.json", "vocab.json", "merges.txt", "tokenizer_config.json"],
            into: cacheDir)
        XCTAssertEqual(Qwen3ASREngine(profile: .large, modelsDir: dir).verifyInstalled(in: dir), true)
    }

    // A partial install that landed weights but not the tokenizer must NOT be adopted — loading it would
    // paste raw token IDs into the user's document.
    func testQwenUnverifiedWhenTokenizerMissing() throws {
        let cacheDir = try qwenCacheDir(profile: .large)
        try writeFiles(
            ["model.safetensors", "config.json", "merges.txt", "tokenizer_config.json"],
            into: cacheDir)
        XCTAssertEqual(Qwen3ASREngine(profile: .large, modelsDir: dir).verifyInstalled(in: dir), false)
    }

    func testQwenUnverifiedWhenTokenizerSidecarMissing() throws {
        let cacheDir = try qwenCacheDir(profile: .large)
        try writeFiles(["model.safetensors", "config.json", "vocab.json", "tokenizer_config.json"], into: cacheDir)
        XCTAssertEqual(Qwen3ASREngine(profile: .large, modelsDir: dir).verifyInstalled(in: dir), false)
    }

    func testQwenUnverifiedWhenWeightsMissing() throws {
        let cacheDir = try qwenCacheDir(profile: .large)
        try writeFiles(["config.json", "vocab.json", "merges.txt", "tokenizer_config.json"], into: cacheDir)
        XCTAssertEqual(Qwen3ASREngine(profile: .large, modelsDir: dir).verifyInstalled(in: dir), false)
    }
}
