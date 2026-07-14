import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct AIServiceModelFetchTests {
    // Creation is now a draft flow; seed the connection directly to exercise edit-existing via update/fetchModels.
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
        let model = AIServiceSettingsModel(repository: repository, listModels: listModels)
        return (model, support)
    }

    private func openAICompatConnection(from model: AIServiceSettingsModel, baseUrl: String, modelId: String) -> Connection {
        var conn = model.selected!
        conn.provider = .openaiCompatible
        conn.baseUrl = baseUrl
        conn.model = modelId
        return conn
    }

    // A fetch keeps only the connection id, so its result belongs to whatever endpoint it queried. If the
    // base URL changes while the fetch is in flight, the stale list must not overwrite the new endpoint's model.
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

    // A model-only edit doesn't change what the endpoint offers, so suggestions still publish — only
    // auto-select is suppressed (covered above).
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

}
