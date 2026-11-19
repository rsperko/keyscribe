import Darwin
import Foundation
import KeyScribeKit

final class CodexDaemonClient: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case unavailable
        case closed
        case timedOut
        case rejected(code: Int?, message: String?)
    }

    private struct Initialize: Encodable {
        struct ClientInfo: Encodable {
            var name: String
            var title: String
            var version: String
        }

        struct Capabilities: Encodable {
            var experimentalApi = true
            var requestAttestation = false
        }

        var clientInfo: ClientInfo
        var capabilities = Capabilities()
    }

    static func socketPath(home: String) -> String {
        (home as NSString).appendingPathComponent("app-server-control/app-server-control.sock")
    }

    let socketPath: String
    private let onNotification: @Sendable (CodexNotification) -> Void
    private let onClose: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.keyscribe.codex-daemon")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var reader = CodexWebSocket.Reader()
    private var key = ""
    private var greeting = Data()
    private var opening: CheckedContinuation<Void, Error>?
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var lastID = 0
    private var open = false

    init(
        socketPath: String, onNotification: @escaping @Sendable (CodexNotification) -> Void, onClose: @escaping @Sendable () -> Void
    ) {
        self.socketPath = socketPath
        self.onNotification = onNotification
        self.onClose = onClose
    }

    var isOpen: Bool { queue.sync { open } }
    var waiting: Int { queue.sync { pending.count } }

    func connect(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { self.begin(continuation, timeout: timeout) }
        }
        let info = Initialize(clientInfo: .init(name: Branding.appName, title: Branding.appName, version: "1"))
        do {
            _ = try await call("initialize", info, timeout: timeout)
        } catch {
            close()
            throw (error as? Failure) == .timedOut ? Failure.unavailable : error
        }
        queue.async { self.send(CodexDaemon.initialized) }
    }

    func call<Params: Encodable & Sendable>(_ method: String, _ params: Params, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                guard self.fd >= 0, self.opening == nil else { return continuation.resume(throwing: Failure.closed) }
                self.lastID += 1
                let id = self.lastID
                guard let request = try? CodexDaemon.request(id: id, method: method, params: params) else {
                    return continuation.resume(throwing: Failure.rejected(code: nil, message: nil))
                }
                self.pending[id] = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) { self.pending.removeValue(forKey: id)?.resume(throwing: Failure.timedOut) }
                self.send(request)
            }
        }
    }

    func close() {
        queue.sync { shut(report: false) }
    }

    private func begin(_ continuation: CheckedContinuation<Void, Error>, timeout: TimeInterval) {
        guard fd < 0 else { return continuation.resume(throwing: Failure.unavailable) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return continuation.resume(throwing: Failure.unavailable) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in path.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return continuation.resume(throwing: Failure.unavailable) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(socketFD)
            return continuation.resume(throwing: Failure.unavailable)
        }
        var noSignal: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var sendLimit = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &sendLimit, socklen_t(MemoryLayout<timeval>.size))
        fd = socketFD
        reader = CodexWebSocket.Reader()
        greeting = Data()
        key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        opening = continuation
        let read = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        read.setEventHandler { [weak self] in self?.readable() }
        read.resume()
        source = read
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let waiting = opening else { return }
            opening = nil
            shut(report: false)
            waiting.resume(throwing: Failure.unavailable)
        }
        write(CodexWebSocket.handshake(key: key))
    }

    private func readable() {
        guard fd >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { return shut(report: true) }
        var bytes = Data(chunk[0..<n])
        if let waiting = opening {
            greeting.append(bytes)
            switch CodexWebSocket.upgrade(greeting, key: key) {
            case .incomplete:
                return
            case .refused:
                opening = nil
                shut(report: false)
                return waiting.resume(throwing: Failure.unavailable)
            case .upgraded(let rest):
                opening = nil
                open = true
                greeting = Data()
                waiting.resume()
                bytes = rest
            }
        }
        for received in reader.read(bytes) {
            switch received {
            case .text(let message): handle(message)
            case .ping(let payload): write(CodexWebSocket.frame(payload, opcode: 0xA, mask: Self.mask()))
            case .closed: return shut(report: true)
            }
        }
    }

    private func handle(_ message: Data) {
        switch CodexDaemon.decode(message) {
        case .response(let id, let result): pending.removeValue(forKey: id)?.resume(returning: result)
        case .error(let id?, let code, let text): pending.removeValue(forKey: id)?.resume(throwing: Failure.rejected(code: code, message: text))
        case .notification(let notification): onNotification(notification)
        case .error(nil, _, _), .serverRequest, .unreadable: break
        }
    }

    private func send(_ message: Data) {
        write(CodexWebSocket.frame(message, mask: Self.mask()))
    }

    private func write(_ data: Data) {
        guard fd >= 0 else { return }
        let sent = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        if !sent { shut(report: true) }
    }

    private func shut(report: Bool) {
        guard fd >= 0 else { return }
        source?.cancel()
        source = nil
        Darwin.close(fd)
        fd = -1
        let wasOpen = open
        open = false
        let failed = pending.values
        pending = [:]
        for waiting in failed { waiting.resume(throwing: Failure.closed) }
        if let waiting = opening {
            opening = nil
            waiting.resume(throwing: Failure.unavailable)
        }
        if report, wasOpen { onClose() }
    }

    private static func mask() -> [UInt8] { (0..<4).map { _ in UInt8.random(in: 0...255) } }
}
