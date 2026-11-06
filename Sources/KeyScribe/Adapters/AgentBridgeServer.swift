import Darwin
import Foundation
import KeyScribeKit

final class AgentBridgeServer: @unchecked Sendable {
    enum StartError: Error { case pathTooLong, socket(Int32) }

    private struct Parked {
        var fd: Int32
        var session: String
        var instance: String
        var connection: String
        var deadline: Date
    }

    let directory: URL
    var socketURL: URL { directory.appendingPathComponent("bridge.sock") }
    var readyURL: URL { directory.appendingPathComponent("ready.json") }
    private(set) var launch: String?

    private let token: String
    private let installation: @Sendable (String) -> String?
    private let pollHold: TimeInterval
    private let onEvent: @Sendable (AgentEvent) -> Void
    private let onHello: @Sendable (AgentEvent.Hello, @escaping @Sendable () -> Void) -> Void
    private let queue = DispatchQueue(label: "com.keyscribe.agent-bridge")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var readers: [Int32: DispatchSourceRead] = [:]
    private var buffers: [Int32: Data] = [:]
    private var parked: [Parked] = []
    private var greeting: Set<Int32> = []
    private var agentByInstance: [String: String] = [:]
    private var commands: AgentCommandQueue

    init(
        directory: URL, token: String, installation: @escaping @Sendable (String) -> String?, pollHold: TimeInterval = 25,
        activeWindow: TimeInterval = AgentCommandQueue.activeWindow,
        onHello: @escaping @Sendable (AgentEvent.Hello, @escaping @Sendable () -> Void) -> Void = { $1() },
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) {
        self.onHello = onHello
        commands = AgentCommandQueue(activeWindow: activeWindow)
        self.directory = directory
        self.token = token
        self.installation = installation
        self.pollHold = pollHold
        self.onEvent = onEvent
    }

    func start() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
        let path = socketURL.path
        unlink(readyURL.path)
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw StartError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in pathBytes.withUnsafeBytes { raw.copyMemory(from: $0) } }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket(errno) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 32) == 0 else {
            let error = errno
            close(fd)
            unlink(path)
            throw StartError.socket(error)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let accept = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        accept.setEventHandler { [weak self] in self?.acceptAll() }
        accept.resume()
        acceptSource = accept

        let tick = DispatchSource.makeTimerSource(queue: queue)
        tick.schedule(deadline: .now() + 0.1, repeating: 0.1)
        tick.setEventHandler { [weak self] in self?.tick() }
        tick.resume()
        timer = tick

        let id = UUID().uuidString
        do {
            try publishReadiness(launch: id)
        } catch {
            stop()
            throw error
        }
        launch = id
    }

    private func publishReadiness(launch id: String) throws {
        let body = try JSONSerialization.data(withJSONObject: ["launch": id, "protocol": AgentBridgeCodec.protocolVersion])
        let staging = directory.appendingPathComponent(".ready-\(id).json")
        guard FileManager.default.createFile(atPath: staging.path, contents: body, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(staging.path, readyURL.path) == 0 else {
            let error = errno
            unlink(staging.path)
            throw StartError.socket(error)
        }
    }

    private func withdrawReadiness() {
        guard let launch,
              let data = FileManager.default.contents(atPath: readyURL.path),
              let ready = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ready["launch"] as? String == launch
        else { return }
        unlink(readyURL.path)
    }

    func stop() {
        queue.sync {
            withdrawReadiness()
            launch = nil
            timer?.cancel()
            acceptSource?.cancel()
            for (fd, reader) in readers {
                reader.cancel()
                close(fd)
            }
            for p in parked { close(p.fd) }
            for fd in greeting { close(fd) }
            greeting = []
            readers = [:]
            buffers = [:]
            parked = []
            if listenFD >= 0 { close(listenFD) }
            listenFD = -1
            unlink(socketURL.path)
        }
    }

    func enqueue(_ command: AgentCommand, for session: String, instance: String? = nil) {
        queue.async {
            self.commands.enqueue(command, for: session, instance: instance, at: Date())
            self.flush(session: session)
        }
    }

    func retire() {
        queue.async {
            self.agentByInstance = [:]
            self.answerRetired(self.commands.retire(), parked: self.parked)
            self.parked = []
        }
    }

    func retire(agent: String) {
        queue.async {
            let belongs: (String) -> Bool = { AgentSessionID.agent(of: $0) == agent }
            self.agentByInstance = self.agentByInstance.filter { $0.value != agent }
            let waiting = self.parked.filter { belongs($0.session) }
            self.parked.removeAll { belongs($0.session) }
            self.answerRetired(self.commands.retire(where: belongs), parked: waiting)
        }
    }

    private func answerRetired(_ refusals: [AgentCommandQueue.Refusal], parked waiting: [Parked]) {
        for refusal in refusals {
            onEvent(.undelivered(request: refusal.command.id, reason: refusal.reason.rawValue, handedOff: refusal.handedOff))
        }
        for p in waiting { respond(p.fd, status: 200, body: Data(#"[{"op":"retire","id":"retire"}]"#.utf8)) }
    }

    func withdraw(_ id: String) -> Bool {
        queue.sync { commands.withdraw(id) }
    }

    func forget(session: String) {
        queue.async { self.commands.forget(session: session) }
    }

    func isLive(session: String) -> Bool {
        queue.sync { commands.isLive(session: session, at: Date()) }
    }

    private func acceptAll() {
        while true {
            let client = Darwin.accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            let reader = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            reader.setEventHandler { [weak self] in self?.readable(client) }
            readers[client] = reader
            buffers[client] = Data()
            reader.resume()
        }
    }

    private func readable(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { return finish(fd) }
        buffers[fd, default: Data()].append(contentsOf: chunk[0..<n])
        switch AgentBridgeHTTP.parse(buffers[fd] ?? Data()) {
        case .incomplete:
            return
        case .invalid:
            respond(fd, status: 400)
        case .request(let request):
            readers.removeValue(forKey: fd)?.cancel()
            buffers[fd] = nil
            handle(request, on: fd)
        }
    }

    private func handle(_ request: AgentBridgeHTTP.Request, on fd: Int32) {
        guard request.method == "POST", request.isAuthorized(token: token) else { return respond(fd, status: 401) }
        switch request.path {
        case "/poll": handlePoll(request.body, on: fd)
        case "/event": handleEvent(request.body, on: fd)
        default: respond(fd, status: 404)
        }
    }

    private func handlePoll(_ body: Data, on fd: Int32) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let native = json["session"] as? String, let instance = json["instance"] as? String,
              let connection = json["connection"] as? String
        else { return respond(fd, status: 400) }
        guard let agent = agentByInstance[instance] else { return respond(fd, status: 409) }
        let session = AgentSessionID.make(agent: agent, native: native)
        let now = Date()
        guard let ready = commands.poll(session: session, instance: instance, connection: connection, at: now) else {
            return respond(fd, status: 409)
        }
        if ready.isEmpty {
            parked.append(Parked(fd: fd, session: session, instance: instance, connection: connection, deadline: now.addingTimeInterval(pollHold)))
        } else {
            send(ready, to: fd)
        }
    }

    private func handleEvent(_ body: Data, on fd: Int32) {
        guard let (received, envelope) = try? AgentBridgeCodec.decodeFrame(body) else {
            return respond(fd, status: 400)
        }
        let event: AgentEvent
        if case .hello(let hello) = received {
            guard hello.protocolVersion == AgentBridgeCodec.protocolVersion else { return respond(fd, status: 426) }
            guard hello.connection != nil else { return respond(fd, status: 400) }
            guard let current = installation(hello.agent), hello.installation == current else { return respond(fd, status: 403) }
            event = received.renamingSession { AgentSessionID.make(agent: hello.agent, native: $0) }
        } else {
            guard let instance = envelope.instance, let connection = envelope.connection,
                  commands.isCurrent(instance: instance, connection: connection), let agent = agentByInstance[instance]
            else { return respond(fd, status: 409) }
            event = received.renamingSession { AgentSessionID.make(agent: agent, native: $0) }
        }
        switch event {
        case .hello(let hello):
            greeting.insert(fd)
            onHello(hello) { [weak self] in
                self?.queue.async { self?.register(hello, answering: fd) }
            }
            return
        case .ack(let request), .submitted(let request, _), .refused(let request, _), .focused(let request):
            if let instance = envelope.instance, let connection = envelope.connection {
                commands.ack(request, instance: instance, connection: connection)
            }
        case .typed, .turnStarted, .turnComplete, .undelivered, .title, .waiting:
            break
        }
        respond(fd, status: 200, body: Data(#"{"ok":true}"#.utf8))
        onEvent(event)
    }

    private func tick() {
        let now = Date()
        for p in parked { commands.touch(instance: p.instance, connection: p.connection, at: now) }
        commands.tick(at: now)
        for refusal in commands.undeliverable(at: now) {
            onEvent(.undelivered(request: refusal.command.id, reason: refusal.reason.rawValue, handedOff: refusal.handedOff))
        }
        let expired = parked.filter { $0.deadline <= now }
        parked.removeAll { $0.deadline <= now }
        for p in expired { send([], to: p.fd) }
        for session in Set(parked.map(\.session)) { flush(session: session) }
    }

    private func flush(session: String) {
        let now = Date()
        var stillParked: [Parked] = []
        for p in parked {
            guard p.session == session else { stillParked.append(p); continue }
            switch commands.poll(session: session, instance: p.instance, connection: p.connection, at: now) {
            case nil: respond(p.fd, status: 409)
            case let ready? where ready.isEmpty: stillParked.append(p)
            case let ready?: send(ready, to: p.fd)
            }
        }
        parked = stillParked
    }

    private func register(_ hello: AgentEvent.Hello, answering fd: Int32) {
        guard greeting.remove(fd) != nil else { return }
        guard let current = installation(hello.agent), hello.installation == current else { return respond(fd, status: 403) }
        agentByInstance[hello.instance] = hello.agent
        if hello.resumesAfterGap {
            for refusal in commands.connectionGap(session: hello.session, instance: hello.instance) {
                onEvent(.undelivered(request: refusal.command.id, reason: refusal.reason.rawValue, handedOff: refusal.handedOff))
            }
        }
        for refusal in commands.hello(session: hello.session, instance: hello.instance, connection: hello.connection ?? "", at: Date()) {
            onEvent(.undelivered(request: refusal.command.id, reason: refusal.reason.rawValue, handedOff: refusal.handedOff))
        }
        let earlier = parked.filter { $0.session == hello.session }
        parked.removeAll { $0.session == hello.session }
        for p in earlier { send([], to: p.fd) }
        respond(fd, status: 200, body: Data(#"{"ok":true}"#.utf8))
        onEvent(.hello(hello))
    }

    private func send(_ commands: [AgentCommand], to fd: Int32) {
        let wire = commands.map { $0.renamingSession(AgentSessionID.native) }
        respond(fd, status: 200, body: (try? AgentBridgeCodec.encode(wire)) ?? Data("[]".utf8))
    }

    private func respond(_ fd: Int32, status: Int, body: Data = Data()) {
        let data = AgentBridgeHTTP.response(status: status, body: body)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, MSG_NOSIGNAL)
                if n <= 0 { break }
                offset += n
            }
        }
        finish(fd)
    }

    private func finish(_ fd: Int32) {
        readers.removeValue(forKey: fd)?.cancel()
        buffers[fd] = nil
        parked.removeAll { $0.fd == fd }
        close(fd)
    }
}
