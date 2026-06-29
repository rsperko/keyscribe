import Foundation
import Testing
@testable import KeyScribeKit

struct ConnectionsTests {
    private let toml = """
    schema_version = 1

    [[connection]]
    id = "gemini-flash"
    name = "Gemini 2.5 Flash"
    provider = "gemini"
    model = "gemini-2.5-flash"
    key_ref = "keyscribe.llm.gemini-flash"
    [connection.params]
    temperature = 0.2
    max_tokens = 2048
    """

    private func connection(provider: Connection.Provider, model: String, baseUrl: String? = nil) -> Connection {
        Connection(id: "c", name: "c", provider: provider, model: model, keyRef: "k", baseUrl: baseUrl)
    }

    @Test func configuredConnectionHasNoIssue() {
        #expect(connection(provider: .openai, model: "gpt-4.1-mini").configIssue == nil)
        #expect(connection(provider: .openaiCompatible, model: "local", baseUrl: "http://127.0.0.1:11234/v1").configIssue == nil)
    }

    @Test func emptyModelIsAnIssue() {
        #expect(connection(provider: .openai, model: "   ").configIssue == .missingModel)
    }

    @Test func openAICompatibleWithoutBaseURLIsAnIssue() {
        #expect(connection(provider: .openaiCompatible, model: "local", baseUrl: nil).configIssue == .missingBaseURL)
        #expect(connection(provider: .openaiCompatible, model: "local", baseUrl: " ").configIssue == .missingBaseURL)
    }

    @Test func tokenCommandAuthWithoutCommandIsAnIssue() {
        let c = Connection(
            id: "c", name: "c", provider: .openaiCompatible, model: "local", keyRef: "k",
            baseUrl: "http://127.0.0.1:11234/v1", authMethod: .tokenCommand)
        #expect(c.configIssue == .missingTokenCommand)
    }

    @Test func nonCompatibleProviderDoesNotNeedBaseURL() {
        #expect(connection(provider: .anthropic, model: "claude-x", baseUrl: nil).configIssue == nil)
    }

    @Test func decodesConnection() throws {
        let set = try ConnectionStore.decode(from: toml)
        let c = try #require(set.connection(id: "gemini-flash"))
        #expect(c.name == "Gemini 2.5 Flash")
        #expect(c.provider == .gemini)
        #expect(c.model == "gemini-2.5-flash")
        #expect(c.keyRef == "keyscribe.llm.gemini-flash")
        #expect(c.params.temperature == 0.2)
        #expect(c.params.maxTokens == 2048)
        #expect(c.baseUrl == nil)
    }

    @Test func decodesTokenCommand() throws {
        let t = """
        schema_version = 1
        [[connection]]
        id = "proxy"
        name = "Proxy"
        provider = "openai_compatible"
        model = "m"
        key_ref = "keyscribe.llm.proxy"
        base_url = "https://proxy.example/v1"
        token_command = "gcloud auth print-access-token"
        """
        let c = try #require(try ConnectionStore.decode(from: t).connection(id: "proxy"))
        #expect(c.tokenCommand == "gcloud auth print-access-token")
        #expect(c.authMethod == .tokenCommand)
    }

    @Test func decodesExplicitNoAuth() throws {
        let t = """
        schema_version = 1
        [[connection]]
        id = "local"
        name = "Local"
        provider = "openai_compatible"
        model = "m"
        key_ref = "keyscribe.llm.local"
        base_url = "http://127.0.0.1:11234/v1"
        auth_method = "none"
        """
        let c = try #require(try ConnectionStore.decode(from: t).connection(id: "local"))
        #expect(c.authMethod == .none)
    }

    @Test func lookupUnknownIsNil() throws {
        let set = try ConnectionStore.decode(from: toml)
        #expect(set.connection(id: "nope") == nil)
    }

    @Test func providerParsesAllVariants() throws {
        for (raw, expected): (String, Connection.Provider) in [
            ("openai", .openai), ("anthropic", .anthropic),
            ("gemini", .gemini), ("openai_compatible", .openaiCompatible),
        ] {
            let t = """
            schema_version = 1
            [[connection]]
            id = "x"
            name = "X"
            provider = "\(raw)"
            model = "m"
            key_ref = "k"
            """
            #expect(try ConnectionStore.decode(from: t).connection(id: "x")?.provider == expected)
        }
    }

    @Test func defaultsParamsWhenAbsent() throws {
        let t = """
        schema_version = 1
        [[connection]]
        id = "x"
        name = "X"
        provider = "gemini"
        model = "m"
        key_ref = "k"
        """
        let c = try #require(try ConnectionStore.decode(from: t).connection(id: "x"))
        #expect(c.params.maxTokens == 2048)   // floor default
    }

    @Test func missingSchemaVersionThrows() {
        #expect(throws: ConfigError.missingSchemaVersion) {
            try ConnectionStore.decode(from: "[[connection]]\nid=\"x\"")
        }
    }

    @Test func emptyConnectionsIsValid() throws {
        let set = try ConnectionStore.decode(from: "schema_version = 1")
        #expect(set.connections.isEmpty)
    }

    @Test func writeThenLoadRoundTripsConnections() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-connection-write-test")
        try? FileManager.default.removeItem(at: dir)
        let original = ConnectionSet(connections: [
            .init(
                id: "local", name: "Local", provider: .openaiCompatible, model: "qwen",
                keyRef: "local-key", tokenCommand: "op read op://ai/token"),
        ])

        try ConnectionStore.write(original, to: dir)
        #expect(ConnectionStore.loadOrDefault(supportDir: dir) == original)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func newIDNormalizesNamesAndAvoidsExistingIDs() {
        #expect(ConnectionStore.newID(for: "My Local AI", existing: []) == "my-local-ai")
        #expect(ConnectionStore.newID(for: "My Local AI", existing: ["my-local-ai"]) == "my-local-ai-2")
    }

    @Test func keyedProvidersDefaultToCurrentModels() {
        #expect(Connection.Provider.openai.defaultModel == "gpt-5.4-mini")
        #expect(Connection.Provider.anthropic.defaultModel == "claude-haiku-4-5")
        #expect(Connection.Provider.gemini.defaultModel == "gemini-2.5-flash")
    }

    @Test func openAICompatibleHasNoDefaultModel() {
        #expect(Connection.Provider.openaiCompatible.defaultModel.isEmpty)
    }

    @Test func providersHaveDefaultNames() {
        #expect(Connection.Provider.openai.defaultName == "OpenAI")
        #expect(Connection.Provider.anthropic.defaultName == "Anthropic")
        #expect(Connection.Provider.gemini.defaultName == "Gemini")
        #expect(Connection.Provider.openaiCompatible.defaultName == "Custom AI")
    }
}
