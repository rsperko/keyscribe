import Foundation

public enum AgentBridgeHTTP {
    public struct Request: Equatable, Sendable {
        public var method: String
        public var path: String
        public var headers: [String: String]
        public var body: Data

        public init(method: String, path: String, headers: [String: String], body: Data) {
            self.method = method
            self.path = path
            self.headers = headers
            self.body = body
        }

        public func isAuthorized(token: String) -> Bool {
            guard let header = headers["authorization"], header.hasPrefix("Bearer ") else { return false }
            let presented = Array(header.dropFirst("Bearer ".count).utf8)
            let expected = Array(token.utf8)
            guard presented.count == expected.count else { return false }
            return zip(presented, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
        }
    }

    public enum ParseResult: Equatable, Sendable {
        case incomplete
        case invalid
        case request(Request)
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)

    public static func parse(_ data: Data) -> ParseResult {
        guard let end = data.range(of: headerEnd) else {
            return data.count > 16 * 1024 ? .invalid : .incomplete
        }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var length = 0
        if let declared = headers["content-length"] {
            guard let n = Int(declared), n >= 0, n <= AgentBridgeCodec.maxFrameBytes else { return .invalid }
            length = n
        }
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return .incomplete }
        let body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: length)])
        return .request(Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body))
    }

    public static func response(status: Int, body: Data) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "Error"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        return out
    }
}
