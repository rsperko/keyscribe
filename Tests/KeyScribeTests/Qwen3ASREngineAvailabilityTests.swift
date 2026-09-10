import AudioCommon
import Foundation
import Testing
@testable import KeyScribeApp
import KeyScribeKit

struct Qwen3ASREngineAvailabilityTests {
    private func tempModelsDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-qwen-availability-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func availabilityFollowsTheShaderLibrary() {
        let dir = tempModelsDir()
        #expect(Qwen3ASREngine(profile: .small, modelsDir: dir, shadersLoadable: false).unavailability
            == .shaderLibraryUnloadable)
        #expect(Qwen3ASREngine(profile: .small, modelsDir: dir, shadersLoadable: true).unavailability == nil)
    }

    @Test func bothLoadsRefuseWithoutCreatingAnything() async throws {
        let dir = tempModelsDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = Qwen3ASREngine(profile: .small, modelsDir: dir, shadersLoadable: false)

        await #expect(throws: EngineUnavailable.self) { try await engine.loadIfNeeded() }
        await #expect(throws: EngineUnavailable.self) { try await engine.load(progress: nil) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func aRefusedInstallLoadLeavesAPopulatedInstallByteForByte() async throws {
        let dir = tempModelsDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = Qwen3ModelProfile.large
        let cacheDir = try HuggingFaceDownloader.getCacheDirectory(
            for: profile.modelId, basePath: dir.appendingPathComponent(profile.subdir, isDirectory: true))
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        var written: [String: Data] = [:]
        for name in ["model.safetensors", "config.json", "vocab.json", "merges.txt", "tokenizer_config.json"] {
            let data = Data("\(name) contents".utf8)
            try data.write(to: cacheDir.appendingPathComponent(name))
            written[name] = data
        }
        let engine = Qwen3ASREngine(profile: profile, modelsDir: dir, shadersLoadable: false)

        await #expect(throws: EngineUnavailable.self) { try await engine.load(progress: nil) }

        let remaining = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        #expect(Set(remaining) == Set(written.keys))
        for (name, data) in written {
            #expect(try Data(contentsOf: cacheDir.appendingPathComponent(name)) == data)
        }
    }
}
