import Foundation
import KeyScribeKit
import Testing

struct CodexWebSocketTests {
    private func serverFrame(_ opcode: UInt8, _ payload: [UInt8], fin: Bool = true) -> Data {
        var frame = Data([(fin ? 0x80 : 0) | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(126)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        } else {
            frame.append(127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xff) })
        }
        frame.append(contentsOf: payload)
        return frame
    }

    @Test func theHandshakeAsksToUpgradeWithItsKey() {
        let text = String(decoding: CodexWebSocket.handshake(key: "dGhlIHNhbXBsZSBub25jZQ=="), as: UTF8.self)
        #expect(text.hasPrefix("GET / HTTP/1.1\r\n"))
        #expect(text.contains("\r\nUpgrade: websocket\r\n"))
        #expect(text.contains("\r\nConnection: Upgrade\r\n"))
        #expect(text.contains("\r\nSec-WebSocket-Version: 13\r\n"))
        #expect(text.contains("\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func anUpgradeIsAcceptedOnlyWithTheAcceptKeyForOurKey() {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let good = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nsec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\nrest".utf8)
        #expect(CodexWebSocket.upgrade(good, key: key) == .upgraded(rest: Data("rest".utf8)))
        let wrong = Data("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: AAAA\r\n\r\n".utf8)
        #expect(CodexWebSocket.upgrade(wrong, key: key) == .refused)
        let refused = Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8)
        #expect(CodexWebSocket.upgrade(refused, key: key) == .refused)
        #expect(CodexWebSocket.upgrade(Data("HTTP/1.1 101 Switching".utf8), key: key) == .incomplete)
    }

    @Test func aClientFrameIsMaskedTextOfEveryLength() {
        for length in [0, 5, 125, 126, 65535, 65536] {
            let payload = Data(repeating: 0x61, count: length)
            let frame = CodexWebSocket.frame(payload, mask: [1, 2, 3, 4])
            #expect(frame[0] == 0x81)
            #expect(frame[1] & 0x80 == 0x80)
            let header = length < 126 ? 2 : length < 65536 ? 4 : 10
            #expect(frame.count == header + 4 + length)
            let mask = Array(frame[header..<(header + 4)])
            #expect(mask == [1, 2, 3, 4])
            let unmasked = frame[(header + 4)...].enumerated().map { $0.element ^ mask[$0.offset % 4] }
            #expect(unmasked == Array(payload))
        }
    }

    @Test func readingCollectsTextAcrossFragmentsAndPartialReads() {
        var reader = CodexWebSocket.Reader()
        let whole = serverFrame(0x1, Array("{\"a\":".utf8), fin: false) + serverFrame(0x0, Array("1}".utf8))
        #expect(reader.read(whole.prefix(3)) == [])
        #expect(reader.read(whole.dropFirst(3)) == [.text(Data("{\"a\":1}".utf8))])
    }

    @Test func readingLongFramesUsesTheExtendedLengths() {
        var reader = CodexWebSocket.Reader()
        let medium = [UInt8](repeating: 0x62, count: 300)
        let long = [UInt8](repeating: 0x63, count: 70000)
        #expect(reader.read(serverFrame(0x1, medium) + serverFrame(0x1, long)) == [.text(Data(medium)), .text(Data(long))])
    }

    @Test func aPingIsReportedSoItCanBeAnsweredAndACloseEndsTheStream() {
        var reader = CodexWebSocket.Reader()
        #expect(reader.read(serverFrame(0x9, [7, 8]) + serverFrame(0x8, [])) == [.ping(Data([7, 8])), .closed])
        #expect(reader.read(serverFrame(0x1, Array("x".utf8))) == [])
    }

    @Test func aPongAnswersWithThePingsPayloadMasked() {
        let pong = CodexWebSocket.frame(Data([7, 8]), opcode: 0xA, mask: [0, 0, 0, 0])
        #expect(Array(pong) == [0x8A, 0x82, 0, 0, 0, 0, 7, 8])
    }

    @Test func aFrameLargerThanTheLimitOrAMaskedServerFrameEndsTheStream() {
        var oversized = CodexWebSocket.Reader(limit: 10)
        #expect(oversized.read(serverFrame(0x1, [UInt8](repeating: 0x61, count: 11))) == [.closed])
        var masked = CodexWebSocket.Reader()
        #expect(masked.read(Data([0x81, 0x81, 0, 0, 0, 0, 0x61])) == [.closed])
        var growing = CodexWebSocket.Reader(limit: 10)
        #expect(growing.read(serverFrame(0x1, Array("123456".utf8), fin: false) + serverFrame(0x0, Array("789012".utf8))) == [.closed])
    }
}
