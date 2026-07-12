import Foundation
import Testing
@testable import KeyScribeKit

struct ConnectionsTests {
    @Test func credentialBoundaryDetectsProviderAndOriginChangesOnly() {
        let original = connection(provider: .openaiCompatible, model: "m", baseUrl: "https://example.com/v1")
        var equivalent = original
        equivalent.baseUrl = "https://example.com/v1/"
        #expect(!original.crossesCredentialBoundary(to: equivalent))

        equivalent.baseUrl = "https://example.com:443/v1"
        #expect(!original.crossesCredentialBoundary(to: equivalent))

        var differentOrigin = original
        differentOrigin.baseUrl = "https://other.example.com/v1"
        #expect(original.crossesCredentialBoundary(to: differentOrigin))

        var differentProvider = original
        differentProvider.provider = .gemini
        #expect(original.crossesCredentialBoundary(to: differentProvider))
    }
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
        #expect(c.params.geminiThinkingLevel == "minimal")
    }

    @Test func absentParamsDecodeToProviderDefaults() throws {
        func decode(_ provider: String) throws -> Connection? {
            let t = """
            schema_version = 1
            [[connection]]
            id = "x"
            name = "X"
            provider = "\(provider)"
            model = "m"
            key_ref = "k"
            """
            return try ConnectionStore.decode(from: t).connection(id: "x")
        }
        #expect(try decode("openai")?.params.reasoningEffort == "none")
        #expect(try decode("anthropic")?.params.reasoningEffort == nil)
        #expect(try decode("openai_compatible")?.params.reasoningEffort == nil)
        #expect(try decode("openai_compatible")?.params.geminiThinkingLevel == nil)
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

    @Test func loadReportsAbsentLoadedAndFailed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-connection-load-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ConnectionStore.load(supportDir: dir) == .absent)
        #expect(ConnectionStore.loadOrDefault(supportDir: dir).connections.isEmpty)

        let set = ConnectionSet(connections: [connection(provider: .gemini, model: "gemini-2.5-flash")])
        try ConnectionStore.write(set, to: dir)
        #expect(ConnectionStore.load(supportDir: dir) == .loaded(set))

        // A present-but-malformed file must surface as .failed, not silently drop every connection.
        try "schema_version = 1\n[[connection]\nid = \"x\"".write(
            to: dir.appendingPathComponent(ConnectionStore.fileName), atomically: true, encoding: .utf8)
        guard case .failed = ConnectionStore.load(supportDir: dir) else {
            Issue.record("expected .failed for malformed connections.toml")
            return
        }
        #expect(ConnectionStore.loadOrDefault(supportDir: dir).connections.isEmpty)
    }

    @Test func loadReportsAPresentButUnreadableFileAsFailedNotAbsent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-connection-unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Present but not valid UTF-8 — must not be mistaken for an absent file and silently defaulted.
        try Data([0xFF, 0xFE, 0x00, 0xFF]).write(to: dir.appendingPathComponent(ConnectionStore.fileName))
        guard case .failed = ConnectionStore.load(supportDir: dir) else {
            Issue.record("expected .failed for a present but unreadable connections.toml")
            return
        }
    }

    @Test func loadReportsNewerSchemaAsFailed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-connection-newer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "schema_version = 99".write(
            to: dir.appendingPathComponent(ConnectionStore.fileName), atomically: true, encoding: .utf8)
        #expect(ConnectionStore.load(supportDir: dir) == .failed(.newerSchemaVersion(found: 99, supported: 1)))
    }

    @Test func newIDNormalizesNamesAndAvoidsExistingIDs() {
        #expect(ConnectionStore.newID(for: "My Local AI", existing: []) == "my-local-ai")
        #expect(ConnectionStore.newID(for: "My Local AI", existing: ["my-local-ai"]) == "my-local-ai-2")
    }

    @Test func keyedProvidersDefaultToCurrentModels() {
        #expect(Connection.Provider.openai.defaultModel == "gpt-5.6-luna")
        #expect(Connection.Provider.anthropic.defaultModel == "claude-haiku-4-5")
        #expect(Connection.Provider.gemini.defaultModel == "gemini-flash-lite-latest")
    }

    @Test func newConnectionsUseProviderSpecificReasoningDefaults() {
        let openAI = Connection(id: "openai", name: "OpenAI", provider: .openai, model: Connection.Provider.openai.defaultModel, keyRef: "k")
        let anthropic = Connection(id: "anthropic", name: "Anthropic", provider: .anthropic, model: Connection.Provider.anthropic.defaultModel, keyRef: "k")
        let gemini = Connection(id: "gemini", name: "Gemini", provider: .gemini, model: Connection.Provider.gemini.defaultModel, keyRef: "k")

        #expect(openAI.params.reasoningEffort == "none")
        #expect(anthropic.params.reasoningEffort == nil)
        #expect(gemini.params.geminiThinkingLevel == "minimal")
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
