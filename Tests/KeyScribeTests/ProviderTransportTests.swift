import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private func transport(
    keyProvider: @escaping @Sendable (String) -> String?,
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
