import CryptoKit
import Darwin
import Foundation

final class FakeCodexDaemon: @unchecked Sendable {
    enum Reply {
        case result(String)
        case error(code: Int, message: String)
        case silent
    }

    struct Call: @unchecked Sendable {
        var method: String
        var params: [String: Any]
    }

    let home: URL
    var socketPath: String { home.appendingPathComponent("app-server-control/app-server-control.sock").path }
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clients: [Int32] = []
    private var calls: [Call] = []
    private var handler: (String, [String: Any]) -> Reply = { _, _ in .result("{}") }
    private var acceptsUpgrade = true

    init() throws {
        home = URL(fileURLWithPath: "/tmp/ks-cx-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("app-server-control"), withIntermediateDirectories: true)
    }

    func answer(_ handler: @escaping (String, [String: Any]) -> Reply) { lock.withLock { self.handler = handler } }

    func refuseUpgrade() { lock.withLock { acceptsUpgrade = false } }

    var received: [Call] { lock.withLock { calls } }

    func methods() -> [String] { received.map(\.method).filter { $0 != "initialize" && $0 != "initialized" } }

    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        unlink(socketPath)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        listenFD = fd
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                lock.withLock { clients.append(client) }
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    func push(_ json: String) {
        for client in lock.withLock({ clients }) { send(client, opcode: 0x1, Data(json.utf8)) }
    }

    func ping() {
        for client in lock.withLock({ clients }) { send(client, opcode: 0x9, Data([1, 2])) }
    }

    func dropClients() {
        for client in lock.withLock({ let all = clients; clients = []; return all }) {
            shutdown(client, SHUT_RDWR)
            close(client)
        }
    }

    func stop() {
        dropClients()
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
        }
        unlink(socketPath)
        try? FileManager.default.removeItem(at: home)
    }

    var pongs: Int { lock.withLock { pongCount } }
    private var pongCount = 0

    private func serve(_ fd: Int32) {
        var buffer = Data()
        guard let end = readUntilHeaders(fd, &buffer) else { return }
        let headers = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        buffer = Data(buffer[end.upperBound...])
        let key = headers.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
        guard lock.withLock({ acceptsUpgrade }) else {
            write(fd, Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8))
            return
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        write(fd, Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
        while let (opcode, payload) = nextFrame(fd, &buffer) {
            if opcode == 0xA { lock.withLock { pongCount += 1 }; continue }
            guard opcode == 0x1, let message = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let method = message["method"] as? String
            else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            let reply = lock.withLock { () -> Reply in
                calls.append(Call(method: method, params: params))
                return method == "initialize" ? .result(#"{"userAgent":"fake"}"#) : handler(method, params)
            }
            guard let id = message["id"] else { continue }
            let idText = (id as? String).map { "\"\($0)\"" } ?? "\(id)"
            switch reply {
            case .result(let json): send(fd, opcode: 0x1, Data(#"{"id":\#(idText),"result":\#(json)}"#.utf8))
            case .error(let code, let text): send(fd, opcode: 0x1, Data(#"{"id":\#(idText),"error":{"code":\#(code),"message":"\#(text)"}}"#.utf8))
            case .silent: break
            }
        }
    }

    private func readUntilHeaders(_ fd: Int32, _ buffer: inout Data) -> Range<Data.Index>? {
        while true {
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) { return end }
            guard let chunk = readSome(fd) else { return nil }
            buffer.append(chunk)
        }
    }

    private func readSome(_ fd: Int32) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &bytes, bytes.count)
        return n > 0 ? Data(bytes[0..<n]) : nil
    }

    private func nextFrame(_ fd: Int32, _ buffer: inout Data) -> (UInt8, Data)? {
        while true {
            let bytes = [UInt8](buffer)
            if bytes.count >= 2 {
                var length = Int(bytes[1] & 0x7f)
                var offset = 2
                if length == 126, bytes.count >= 4 {
                    length = Int(bytes[2]) << 8 | Int(bytes[3])
                    offset = 4
                } else if length == 127, bytes.count >= 10 {
                    length = Int(bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
                    offset = 10
                }
                if length < 126 || offset > 2, bytes.count >= offset + 4 + length {
                    let mask = Array(bytes[offset..<(offset + 4)])
                    let payload = Data(bytes[(offset + 4)..<(offset + 4 + length)].enumerated().map { $0.element ^ mask[$0.offset % 4] })
                    buffer = Data(bytes[(offset + 4 + length)...])
                    return (bytes[0] & 0x0f, payload)
                }
            }
            guard let chunk = readSome(fd) else { return nil }
            buffer.append(chunk)
        }
    }

    private func send(_ fd: Int32, opcode: UInt8, _ payload: Data) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        } else {
            frame.append(127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xff) })
        }
        frame.append(payload)
        write(fd, frame)
    }

    private func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, MSG_NOSIGNAL)
                if n <= 0 { return }
                offset += n
            }
        }
    }
}
