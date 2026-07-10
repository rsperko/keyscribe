import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private func transport(
    keyProvider: @escaping @Sendable (String) -> String?,
    session: URLSession = URLSession(configuration: .ephemeral)
) -> ProviderTransport {
    lookupTransport(keyProvider: { keyProvider($0).map(SecretLookup.found) ?? .absent }, session: session)
}

private func lookupTransport(
    keyProvider: @escaping @Sendable (String) -> SecretLookup,
    session: URLSession = URLSession(configuration: .ephemeral)
) -> ProviderTransport {
    ProviderTransport(
        session: session,
        keyProvider: keyProvider,
        tokenCommandRunner: { _ in "" },
        tokenCache: TokenCommandCache(),
        now: { Date(timeIntervalSince1970: 0) })
}

private final class ErrorStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (code, data) = Self.response ?? (200, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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

    @Test func aDeniedKeychainThrowsKeychainDeniedNotMissingKey() async {
        let t = lookupTransport(keyProvider: { _ in .denied(status: -25308) })
        await #expect {
            _ = try await t.credential(for: connection, apiKey: nil)
        } throws: { error in
            guard case ProviderTransportError.keychainDenied(let ref, let status) = error else { return false }
            return ref == "ref" && status == -25308
        }
    }

    @Test func anAbsentKeyStillResolvesToNil() async throws {
        let t = lookupTransport(keyProvider: { _ in .absent })
        let key = try await t.credential(for: connection, apiKey: nil)
        #expect(key == nil)
    }

    @Test func aDeniedKeychainIsBypassedByAnExplicitOverride() async throws {
        let t = lookupTransport(keyProvider: { _ in .denied(status: -25308) })
        let key = try await t.credential(for: connection, apiKey: "override")
        #expect(key == "override")
    }

    @Test func httpErrorDescriptionSurfacesTheProviderBody() {
        let withBody = ProviderTransportError.http(404, body: "model not found")
        #expect(withBody.description.contains("404"))
        #expect(withBody.description.contains("model not found"))
        #expect(ProviderTransportError.http(500, body: nil).description == "The model service returned an error (500).")
    }

    @Test func errorSnippetTrimsBlankAndTruncatesLongBodies() {
        #expect(ProviderTransport.errorSnippet(from: Data()) == nil)
        #expect(ProviderTransport.errorSnippet(from: Data("   \n ".utf8)) == nil)
        #expect(ProviderTransport.errorSnippet(from: Data("  hi  ".utf8)) == "hi")
        let long = String(repeating: "x", count: 500)
        let snippet = ProviderTransport.errorSnippet(from: Data(long.utf8), limit: 300)
        #expect(snippet?.hasSuffix("…") == true)
        #expect(snippet?.count == 301)
    }

    // A large provider error body (local vLLM/oMLX servers) must stay parseable: send wires errorBody (the
    // full payload) into the HTTP error so OpenAIAPIError.parse still recovers error.code/param that the
    // 400-remediation loop and model-not-found detection depend on. A >1000-char truncation would be invalid
    // JSON and silently disable both.
    @Test func errorBodyKeepsLargePayloadParseableBeyond1000Chars() {
        let padding = String(repeating: "x", count: 1500)
        let bodyJSON = "{\"error\":{\"message\":\"\(padding)\",\"code\":\"model_not_found\",\"param\":\"model\"}}"
        #expect(bodyJSON.count > 1000)
        let body = ProviderTransport.errorBody(from: Data(bodyJSON.utf8))
        #expect(body?.count == bodyJSON.count)
        #expect(OpenAIAPIError.parse(body: body)?.indicatesMissingModel == true)
    }

    @Test func sendWiresANon2xxResponseBodyIntoTheHTTPError() async {
        ErrorStubProtocol.response = (404, Data(#"{"error":"model not found"}"#.utf8))
        defer { ErrorStubProtocol.response = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ErrorStubProtocol.self]
        let t = transport(keyProvider: { _ in nil }, session: URLSession(configuration: config))
        let request = URLRequest(url: URL(string: "http://127.0.0.1/v1/chat/completions")!)
        await #expect {
            _ = try await t.send(request)
        } throws: { error in
            guard case ProviderTransportError.http(let code, let body) = error else { return false }
            return code == 404 && (body?.contains("model not found") ?? false)
        }
    }
}
