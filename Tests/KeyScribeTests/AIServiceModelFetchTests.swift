import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

@MainActor
struct AIServiceModelFetchTests {
    // Seeds one existing connection (these tests exercise the unchanged edit-existing path via update/
    // fetchModels; creation is now a draft flow, so seed the connection directly instead of model.create()).
    private func makeModel(
        listModels: @escaping (Connection, String?) async throws -> [String]
    ) -> (AIServiceSettingsModel, URL) {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("keyscribe-ai-\(UUID().uuidString)")
        try! fm.createDirectory(at: support.appendingPathComponent("modes"), withIntermediateDirectories: true)
        let repository = ConfigRepository(supportDir: support, config: ConfigCache(supportDir: support))
        let seed = Connection(
            id: "new-ai-service", name: "New AI Service", provider: .openai,
            model: Connection.Provider.openai.defaultModel, keyRef: "keyscribe.llm.new-ai-service")
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

    // A fetch retains only the connection id; its result belongs to the endpoint it queried. If the user
    // repoints the base URL while the fetch is in flight, the stale list's models[0] must not overwrite the
    // model on the now-different endpoint.
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
        // The old endpoint's list is not offered as suggestions for the new endpoint, and discovery is
        // left idle so the user re-fetches.
        #expect(model.modelSuggestions(for: id).isEmpty)
        #expect(model.modelDiscoveryState(for: id) == nil)
    }

    // A model-only edit does not change what the endpoint offers, so the suggestions are still valid and
    // are published — only the auto-select is suppressed (covered above).
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

    // Same endpoint, but the user picks a different model while the fetch is in flight. The stale list may
    // not include their choice; the auto-select must not overwrite a deliberate model pick.
    @Test func modelEditedDuringFetchIsNotClobbered() async {
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
    }

    // The auto-select still runs when the endpoint is unchanged: a model absent from the fetched list is
    // replaced with the first offered model.
    @Test func fetchAutoSelectsWhenTheEndpointIsUnchanged() async {
        let (model, support) = makeModel { _, _ in ["server-model"] }
        defer { try? FileManager.default.removeItem(at: support) }
        let conn = openAICompatConnection(from: model, baseUrl: "http://host/v1", modelId: "not-in-list")
        model.update(conn, apiKey: nil)
        let id = conn.id

        await model.fetchModels(for: model.selected!, apiKey: nil)

        #expect(model.connections.first { $0.id == id }?.model == "server-model")
    }
}
