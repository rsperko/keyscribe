import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

@MainActor
struct AIServiceModelFetchTests {
    private func makeModel(
        listModels: @escaping (Connection, String?) async throws -> [String]
    ) -> (AIServiceSettingsModel, URL) {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("keyscribe-ai-\(UUID().uuidString)")
        try! fm.createDirectory(at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        let seed = Connection(
            id: "new-ai-service", name: "New AI Service", provider: .openai,
            model: "gpt-5.6-luna", keyRef: "keyscribe.llm.new-ai-service")
        try! repository.upsertConnection(seed)
        let model = AIServiceSettingsModel(repository: repository, permits: { _ in true }, listModels: listModels)
        return (model, support)
    }

    private func openAICompatConnection(from model: AIServiceSettingsModel, baseUrl: String, modelId: String) -> Connection {
        var conn = model.selected!
        conn.provider = .openaiCompatible
        conn.baseUrl = baseUrl
        conn.model = modelId
        return conn
    }

    @Test func staleFetchDoesNotOverwriteAModelAfterTheBaseURLChanged() async {
        let (model, support) = makeModel { _, _ in ["only-on-old-server"] }
        defer { try? FileManager.default.removeItem(at: support) }
        let stale = openAICompatConnection(from: model, baseUrl: "http://old/v1", modelId: "keep-me")
        model.update(stale, apiKey: nil)
        let id = stale.id

        var repointed = model.selected!
        repointed.baseUrl = "http://new/v1"
        model.update(repointed, apiKey: nil)

        await model.fetchModels(for: stale, apiKey: nil)

        #expect(model.connections.first { $0.id == id }?.model == "keep-me")
        #expect(model.connections.first { $0.id == id }?.baseUrl == "http://new/v1")
        #expect(model.modelSuggestions(for: id).isEmpty)
        #expect(model.modelDiscoveryState(for: id) == nil)
    }

    @Test func modelEditPublishesSuggestionsButKeepsTheUsersModel() async {
        let (model, support) = makeModel { _, _ in ["server-a", "server-b"] }
        defer { try? FileManager.default.removeItem(at: support) }
        let stale = openAICompatConnection(from: model, baseUrl: "http://host/v1", modelId: "old-model")
        model.update(stale, apiKey: nil)
        let id = stale.id

        var edited = model.selected!
        edited.model = "my-choice"
        model.update(edited, apiKey: nil)

        await model.fetchModels(for: stale, apiKey: nil)

        #expect(model.connections.first { $0.id == id }?.model == "my-choice")
        #expect(model.modelSuggestions(for: id) == ["server-a", "server-b"])
        #expect(model.modelDiscoveryState(for: id) == .loaded)
    }


    @Test func fetchedMetadataIsKeptPerModelAndItsOutputCeilingIsSaved() async {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("keyscribe-ai-\(UUID().uuidString)")
        try! fm.createDirectory(at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: support) }
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        let seed = Connection(
            id: "router", name: "Router", provider: .openaiCompatible, model: "moonshotai/kimi-k3",
            keyRef: "k", baseUrl: "https://openrouter.ai/api/v1")
        try! repository.upsertConnection(seed)
        let support3 = ModelReasoningSupport(levels: ["low", "high", "max"], canTurnOff: false, maxOutputTokens: 32768)
        let model = AIServiceSettingsModel(
            repository: repository, permits: { _ in true },
            listModelDetails: { _, _ in [ModelListing(id: "moonshotai/kimi-k3", reasoning: support3), ModelListing(id: "other")] })

        await model.fetchModels(for: seed, apiKey: nil)

        #expect(model.modelSuggestions(for: "router") == ["moonshotai/kimi-k3", "other"])
        #expect(model.modelReasoning(for: "router")?.models == ["moonshotai/kimi-k3": support3])
        #expect(model.connections.first?.params.outputCeiling == 32768)

        var samePath = seed
        samePath.name = "Renamed"
        model.update(samePath, apiKey: nil)
        #expect(model.modelReasoning(for: "router") != nil)

        var moved = seed
        moved.baseUrl = "https://openrouter.ai/api/v2"
        model.update(moved, apiKey: nil)
        #expect(model.modelReasoning(for: "router") == nil)
    }
}
