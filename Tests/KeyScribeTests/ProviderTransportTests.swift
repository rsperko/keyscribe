import Foundation
import Testing
@testable import KeyScribeApp
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

// Serves one redirect to `target`, then 200s. Records every URL it is asked to load, so a test can assert
// the redirect target was never CONTACTED — not merely that the call surfaced an error.
private final class RedirectStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 307
    nonisolated(unsafe) static var origin = "http://origin.test/v1/chat"
    nonisolated(unsafe) static var target = "http://elsewhere.test/v1/chat"
    nonisolated(unsafe) static var loaded: [String] = []

    static func reset(status: Int, target: String) {
        self.status = status
        self.target = target
        loaded = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.loaded.append(url.absoluteString)
        if url.absoluteString == Self.origin {
            let resp = HTTPURLResponse(
                url: url, statusCode: Self.status, httpVersion: nil,
                headerFields: ["Location": Self.target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: Self.target)!), redirectResponse: resp)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func redirectSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RedirectStubProtocol.self]
    return URLSession(configuration: config)
}

// Serialized: the stub's routing table is static, so parallel cases would rewrite each other's status.
@Suite(.serialized)
struct RewriteRedirectPinningTests {
    private func post() -> URLRequest {
        var req = URLRequest(url: URL(string: RedirectStubProtocol.origin)!)
        req.httpMethod = "POST"
        req.httpBody = Data(#"{"messages":[{"role":"user","content":"secret transcript"}]}"#.utf8)
        return req
    }

    // 307/308 preserve the method AND the body, so an unpinned redirect replays the prompt and the
    // tokenized transcript to another host. The assertion that matters is that the other host is never
    // contacted at all.
    @Test(arguments: [301, 302, 303, 307, 308])
    func crossOriginRedirectsNeverReachTheTarget(status: Int) async {
        RedirectStubProtocol.reset(status: status, target: "http://elsewhere.test/v1/chat")
        let t = lookupTransport(keyProvider: { _ in .absent }, session: redirectSession())

        _ = try? await t.send(post())

        #expect(!RedirectStubProtocol.loaded.contains("http://elsewhere.test/v1/chat"))
    }

    @Test func aDifferentPortOnTheSameHostIsStillCrossOrigin() async {
        RedirectStubProtocol.reset(status: 307, target: "http://origin.test:8443/v1/chat")
        let t = lookupTransport(keyProvider: { _ in .absent }, session: redirectSession())

        _ = try? await t.send(post())

        #expect(!RedirectStubProtocol.loaded.contains("http://origin.test:8443/v1/chat"))
    }

    @Test func sameOriginRedirectsAreStillFollowed() async throws {
        RedirectStubProtocol.reset(status: 307, target: "http://origin.test/v2/chat")
        let t = lookupTransport(keyProvider: { _ in .absent }, session: redirectSession())

        _ = try await t.send(post())

        #expect(RedirectStubProtocol.loaded.contains("http://origin.test/v2/chat"))
    }
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

    // send wires the full errorBody into the HTTP error so OpenAIAPIError.parse still recovers
    // error.code/param, which the 400-remediation loop and model-not-found detection depend on — a
    // >1000-char truncation would produce invalid JSON and silently disable both.
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
