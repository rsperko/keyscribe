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
            .init(id: "local", name: "Local", provider: .openaiCompatible, model: "qwen", keyRef: "local-key"),
        ])

        try ConnectionStore.write(original, to: dir)
        #expect(ConnectionStore.loadOrDefault(supportDir: dir) == original)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func newIDNormalizesNamesAndAvoidsExistingIDs() {
        #expect(ConnectionStore.newID(for: "My Local AI", existing: []) == "my-local-ai")
        #expect(ConnectionStore.newID(for: "My Local AI", existing: ["my-local-ai"]) == "my-local-ai-2")
    }
}
