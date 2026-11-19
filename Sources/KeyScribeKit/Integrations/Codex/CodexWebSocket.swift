import CryptoKit
import Foundation

public enum CodexWebSocket {
    public static let messageLimit = 16 * 1024 * 1024
    private static let acceptSuffix = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    public enum Upgrade: Equatable, Sendable {
        case upgraded(rest: Data)
        case refused
        case incomplete
    }

    public enum Received: Equatable, Sendable {
        case text(Data)
        case ping(Data)
        case closed
    }

    public static func handshake(key: String) -> Data {
        Data(
            "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n\r\n"
                .utf8)
    }

    public static func upgrade(_ received: Data, key: String) -> Upgrade {
        guard let end = received.range(of: Data("\r\n\r\n".utf8)) else { return received.count > 16 * 1024 ? .refused : .incomplete }
        let lines = String(decoding: received[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard let status = lines.first?.split(separator: " "), status.count >= 2, status[1] == "101" else { return .refused }
        let expected = Data(Insecure.SHA1.hash(data: Data((key + acceptSuffix).utf8))).base64EncodedString()
        let accepted = lines.dropFirst().contains { line in
            guard let colon = line.firstIndex(of: ":") else { return false }
            return line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "sec-websocket-accept"
                && line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) == expected
        }
        return accepted ? .upgraded(rest: Data(received[end.upperBound...])) : .refused
    }

    public static func frame(_ payload: Data, opcode: UInt8 = 0x1, mask: [UInt8]) -> Data {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count < 65536 {
            frame.append(contentsOf: [0x80 | 126, UInt8(count >> 8), UInt8(count & 0xff)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(count) >> (UInt64($0) * 8)) & 0xff) })
        }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }

    public struct Reader: Sendable {
        private let limit: Int
        private var buffer = Data()
        private var partial: Data?
        private var ended = false

        public init(limit: Int = CodexWebSocket.messageLimit) {
            self.limit = limit
        }

        public mutating func read(_ bytes: Data) -> [Received] {
            guard !ended else { return [] }
            buffer.append(bytes)
            var received: [Received] = []
            while let next = nextFrame() {
                guard let item = next else {
                    end()
                    return received + [.closed]
                }
                received.append(contentsOf: item)
                if item == [.closed] {
                    end()
                    return received
                }
            }
            return received
        }

        private mutating func end() {
            ended = true
            buffer = Data()
            partial = nil
        }

        private mutating func nextFrame() -> [Received]?? {
            let bytes = [UInt8](buffer.prefix(10))
            guard bytes.count >= 2 else { return nil }
            guard bytes[1] & 0x80 == 0 else { return .some(nil) }
            var length = Int(bytes[1] & 0x7f)
            var offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return nil }
                length = Int(bytes[2]) << 8 | Int(bytes[3])
                offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return nil }
                let wide = bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard wide <= UInt64(limit) else { return .some(nil) }
                length = Int(wide)
                offset = 10
            }
            guard length <= limit else { return .some(nil) }
            guard buffer.count >= offset + length else { return nil }
            let start = buffer.startIndex
            let payload = Data(buffer[(start + offset)..<(start + offset + length)])
            buffer = Data(buffer[(start + offset + length)...])
            let fin = bytes[0] & 0x80 != 0
            switch bytes[0] & 0x0f {
            case 0x1:
                guard partial == nil else { return .some(nil) }
                return .some(complete(payload, fin: fin))
            case 0x0:
                guard partial != nil else { return .some(nil) }
                return .some(complete(payload, fin: fin))
            case 0x8:
                return .some([.closed])
            case 0x9:
                return .some([.ping(payload)])
            case 0xA:
                return .some([])
            default:
                return .some(nil)
            }
        }

        private mutating func complete(_ payload: Data, fin: Bool) -> [Received]? {
            var message = partial ?? Data()
            message.append(payload)
            guard message.count <= limit else { return nil }
            guard fin else {
                partial = message
                return []
            }
            partial = nil
            return [.text(message)]
        }
    }
}
