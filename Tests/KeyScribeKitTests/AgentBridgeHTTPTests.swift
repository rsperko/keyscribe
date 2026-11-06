import Foundation
import Testing
@testable import KeyScribeKit

struct AgentBridgeHTTPTests {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func aCompleteRequestParsesWithItsBody() {
        let raw = "POST /poll HTTP/1.1\r\nHost: ks\r\nAuthorization: Bearer t0k\r\nContent-Length: 5\r\n\r\nhello"
        #expect(AgentBridgeHTTP.parse(bytes(raw)) == .request(.init(
            method: "POST", path: "/poll", headers: ["host": "ks", "authorization": "Bearer t0k", "content-length": "5"],
            body: bytes("hello"))))
    }

    @Test func aRequestIsIncompleteUntilItsBodyArrives() {
        #expect(AgentBridgeHTTP.parse(bytes("POST /poll HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel")) == .incomplete)
        #expect(AgentBridgeHTTP.parse(bytes("POST /poll HTTP/1.1\r\nContent-")) == .incomplete)
    }

    @Test func aRequestWithNoBodyNeedsNoLength() {
        #expect(AgentBridgeHTTP.parse(bytes("GET /health HTTP/1.1\r\n\r\n")) == .request(.init(method: "GET", path: "/health", headers: [:], body: Data())))
    }

    @Test func malformedOrOversizeRequestsAreInvalid() {
        #expect(AgentBridgeHTTP.parse(bytes("nonsense\r\n\r\n")) == .invalid)
        #expect(AgentBridgeHTTP.parse(bytes("POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n")) == .invalid)
        let tooLong = "POST /event HTTP/1.1\r\nContent-Length: \(AgentBridgeCodec.maxFrameBytes + 1)\r\n\r\n"
        #expect(AgentBridgeHTTP.parse(bytes(tooLong)) == .invalid)
    }

    @Test func responsesCarryTheirLengthAndClose() {
        let response = String(decoding: AgentBridgeHTTP.response(status: 200, body: bytes("[]")), as: UTF8.self)
        #expect(response == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]")
        #expect(String(decoding: AgentBridgeHTTP.response(status: 401, body: Data()), as: UTF8.self).hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
    }

    @Test func theTokenMustMatchExactly() {
        let request = AgentBridgeHTTP.Request(method: "POST", path: "/poll", headers: ["authorization": "Bearer abc"], body: Data())
        #expect(request.isAuthorized(token: "abc"))
        #expect(!request.isAuthorized(token: "abcd"))
        #expect(!AgentBridgeHTTP.Request(method: "POST", path: "/poll", headers: [:], body: Data()).isAuthorized(token: "abc"))
    }
}
