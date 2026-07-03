import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private func transport(keyProvider: @escaping @Sendable (String) -> String?) -> ProviderTransport {
    ProviderTransport(
        session: URLSession(configuration: .ephemeral),
        keyProvider: keyProvider,
        tokenCommandRunner: { _ in "" },
        tokenCache: TokenCommandCache(),
        now: { Date(timeIntervalSince1970: 0) })
}

struct ProviderTransportTests {
    private let connection = Connection(
        id: "c", name: "C", provider: .openaiCompatible,
        model: "m", keyRef: "ref", baseUrl: "http://127.0.0.1/v1")

    @Test func apiKeyOverrideIsPreferredAndTrimmed() async throws {
        let t = transport(keyProvider: { _ in "stored" })
        let key = try await t.credential(for: connection, apiKey: "  override  ")
        #expect(key == "override")
    }

    @Test func blankOverrideFallsBackToTheTrimmedStoredKey() async throws {
        let t = transport(keyProvider: { _ in "  stored  " })
        let key = try await t.credential(for: connection, apiKey: "   ")
        #expect(key == "stored")
    }

    @Test func missingOverrideUsesTheTrimmedStoredKey() async throws {
        let t = transport(keyProvider: { ref in ref == "ref" ? "  stored  " : nil })
        let key = try await t.credential(for: connection, apiKey: nil)
        #expect(key == "stored")
    }

    @Test func authMethodNoneReturnsNilRegardlessOfOverride() async throws {
        var noAuth = connection
        noAuth.authMethod = .none
        let t = transport(keyProvider: { _ in "stored" })
        let key = try await t.credential(for: noAuth, apiKey: "override")
        #expect(key == nil)
    }
}
