import Darwin
import Foundation
import KeyScribeKit

final class AgentBridgeServer: @unchecked Sendable {
    enum StartError: Error { case pathTooLong, socket(Int32) }

    private struct Member: Equatable {
        var session: String
        var instance: String
    }

    private struct Parked {
        var fd: Int32
        var members: [Member]
        var connection: String
        var deadline: Date
        var shared: Bool
        var unknown: [String] = []
    }

    let directory: URL
    var socketURL: URL { directory.appendingPathComponent("bridge.sock") }
    var readyURL: URL { directory.appendingPathComponent("ready.json") }
    private(set) var launch: String?

    private let token: String
    private let admits: @Sendable (_ agent: String, _ installation: String?) -> Bool
    private let excludes: @Sendable (_ session: String) -> Bool
    private let pollHold: TimeInterval
    private let onEvent: @Sendable (AgentEvent) -> Void
    private let onHello: @Sendable (AgentEvent.Hello, @escaping @Sendable (_ filedUnder: String?) -> Void) -> Void
    private let onNotify: @Sendable (AgentEvent, @escaping @Sendable (Bool) -> Void) -> Void
    private let queue = DispatchQueue(label: "com.keyscribe.agent-bridge")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var wake: Date?
    private var readers: [Int32: DispatchSourceRead] = [:]
    private var buffers: [Int32: Data] = [:]
    private var parked: [Parked] = []
    private var greeting: Set<Int32> = []
    private var agentByInstance: [String: String] = [:]
    private var installationByInstance: [String: String] = [:]
    private var filedByInstance: [String: (id: String, native: String)] = [:]
    private var sessionByInstance: [String: String] = [:]
    private var commands: AgentCommandQueue
    private var silenced: Set<String> = []

    init(
        directory: URL, token: String, admits: @escaping @Sendable (_ agent: String, _ installation: String?) -> Bool,
        excludes: @escaping @Sendable (_ session: String) -> Bool = { _ in false }, pollHold: TimeInterval = 25,
        activeWindow: TimeInterval = AgentCommandQueue.activeWindow,
        onHello: @escaping @Sendable (AgentEvent.Hello, @escaping @Sendable (_ filedUnder: String?) -> Void) -> Void = { $1(nil) },
        onNotify: @escaping @Sendable (AgentEvent, @escaping @Sendable (Bool) -> Void) -> Void = { $1(false) },
        onEvent: @escaping @Sendable (AgentEvent) -> Void
    ) {
        self.onHello = onHello
        self.onNotify = onNotify
        commands = AgentCommandQueue(activeWindow: activeWindow)
        self.directory = directory
        self.token = token
        self.admits = admits
        self.excludes = excludes
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
        tick.schedule(deadline: .distantFuture)
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
            wake = nil
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
            self.reschedule()
        }
    }

    func retire() {
        queue.async {
            self.agentByInstance = [:]
            self.installationByInstance = [:]
            self.filedByInstance = [:]
            self.sessionByInstance = [:]
            self.answerRetired(self.commands.retire(), parked: self.parked)
            self.parked = []
            self.reschedule()
        }
    }

    func retire(installation: String) {
        queue.async {
            let instances = Set(self.installationByInstance.filter { $0.value == installation }.keys)
            guard !instances.isEmpty else { return }
            for instance in instances {
                self.agentByInstance[instance] = nil
                self.installationByInstance[instance] = nil
                self.filedByInstance[instance] = nil
                self.sessionByInstance[instance] = nil
            }
            let waiting = self.parked.filter { $0.members.contains { instances.contains($0.instance) } }
            self.parked.removeAll { $0.members.contains { instances.contains($0.instance) } }
            self.answerRetired(self.commands.retire(instances: instances), parked: waiting)
            self.reschedule()
        }
    }

    private func answerRetired(_ refusals: [AgentCommandQueue.Refusal], parked waiting: [Parked]) {
        for refusal in refusals {
            onEvent(.undelivered(request: refusal.command.id, reason: refusal.reason.rawValue, handedOff: refusal.handedOff))
        }
        for p in waiting { respond(p.fd, status: 200, body: Data(#"[{"op":"retire","id":"retire"}]"#.utf8)) }
    }

    func silence(agents: Set<String>) {
        queue.async {
            let changed = self.silenced.symmetricDifference(agents)
            self.silenced = agents
            self.sendBack(Set(self.agentByInstance.filter { changed.contains($0.value) }.keys))
            self.reschedule()
        }
    }

    private func quiets(_ session: String) -> Bool {
        excludes(session) || AgentSessionID.agent(of: session).map(silenced.contains) == true
    }

    func rehello(session: String) {
        queue.async {
            self.sendBack(Set(self.sessionByInstance.filter { $0.value == session }.keys))
            self.reschedule()
        }
    }

    private func sendBack(_ instances: Set<String>) {
        guard !instances.isEmpty else { return }
        for instance in instances {
            agentByInstance[instance] = nil
            filedByInstance[instance] = nil
            sessionByInstance[instance] = nil
        }
        var kept: [Parked] = []
        for var p in parked {
            guard p.members.contains(where: { instances.contains($0.instance) }) else { kept.append(p); continue }
            guard p.shared else { respond(p.fd, status: 409); continue }
            p.unknown += p.members.filter { instances.contains($0.instance) }.map(\.instance)
            p.members.removeAll { instances.contains($0.instance) }
            answer(p, with: [])
        }
        parked = kept
    }

    private func session(native: String, instance: String, agent: String) -> String {
        guard let filed = filedByInstance[instance], filed.native == native else { return AgentSessionID.make(agent: agent, native: native) }
        return filed.id
    }

    private func native(of session: String, on instance: String) -> String {
        guard let filed = filedByInstance[instance], filed.id == session else { return AgentSessionID.native(session) }
        return filed.native
    }

    func withdraw(_ id: String) -> Bool {
        queue.sync { commands.withdraw(id) }
    }

    func forget(session: String) {
        queue.async { self.commands.forget(session: session) }
    }

    func isLive(session: String) -> Bool {
        queue.sync {
            let now = Date()
            touchParked(at: now)
            return commands.isLive(session: session, at: now)
        }
    }

    var nextWake: Date? { queue.sync { wake } }

    private func touchParked(at now: Date) {
        for p in parked {
            for member in p.members { commands.touch(instance: member.instance, connection: p.connection, at: min(now, p.deadline)) }
        }
    }

    private func reschedule() {
        guard let timer, let next = commands.isSettled ? parked.map(\.deadline).min() : Date().addingTimeInterval(0.1) else { return }
        if let wake, wake <= next { return }
        wake = next
        timer.schedule(wallDeadline: .now() + max(0, next.timeIntervalSinceNow))
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
            reschedule()
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
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let connection = json["connection"] as? String
        else { return respond(fd, status: 400) }
        let asked: [(native: String, instance: String)]
        let shared = json["members"] != nil
        if shared {
            guard let list = json["members"] as? [[String: Any]], !list.isEmpty else { return respond(fd, status: 400) }
            let pairs = list.compactMap { item in
                (item["session"] as? String).flatMap { native in (item["instance"] as? String).map { (native, $0) } }
            }
            guard pairs.count == list.count else { return respond(fd, status: 400) }
            asked = pairs
        } else {
            guard let native = json["session"] as? String, let instance = json["instance"] as? String else { return respond(fd, status: 400) }
            asked = [(native, instance)]
        }
        let now = Date()
        touchParked(at: now)
        var members: [Member] = []
        var unknown: [String] = []
        var ready: [(Member, [AgentCommand])] = []
        for (native, instance) in asked {
            guard let agent = agentByInstance[instance], filedByInstance[instance].map({ $0.native == native }) ?? true else {
                unknown.append(instance)
                continue
            }
            let member = Member(session: self.session(native: native, instance: instance, agent: agent), instance: instance)
            guard let found = commands.poll(session: member.session, instance: instance, connection: connection, at: now) else {
                unknown.append(instance)
                continue
            }
            members.append(member)
            if !found.isEmpty { ready.append((member, found)) }
        }
        guard !members.isEmpty else { return respond(fd, status: 409) }
        let p = Parked(fd: fd, members: members, connection: connection, deadline: now.addingTimeInterval(pollHold), shared: shared, unknown: unknown)
        if ready.isEmpty && unknown.isEmpty {
            parked.append(p)
        } else {
            answer(p, with: ready)
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
            guard admits(hello.agent, hello.installation) else { return respond(fd, status: 403) }
            event = received.renamingSession { AgentSessionID.make(agent: hello.agent, native: $0) }
        } else {
            guard let instance = envelope.instance, let connection = envelope.connection,
                  commands.isCurrent(instance: instance, connection: connection), let agent = agentByInstance[instance]
            else { return respond(fd, status: 409) }
            event = received.renamingSession { self.session(native: $0, instance: instance, agent: agent) }
            if let session = event.session, quiets(session) {
                return respond(fd, status: 200, body: Data(#"{"ok":true,"quiet":true}"#.utf8))
            }
        }
        switch event {
        case .hello(let hello):
            greeting.insert(fd)
            onHello(hello) { [weak self] filed in
                self?.queue.async { [weak self] in self?.register(hello, filedUnder: filed, answering: fd) }
            }
            return
        case .ack(let request), .submitted(let request, _, _), .refused(let request, _, _), .focused(let request):
            if let instance = envelope.instance, let connection = envelope.connection {
                commands.ack(request, instance: instance, connection: connection)
            }
        case .notify:
            onNotify(event) { [weak self] spoken in
                self?.queue.async { [weak self] in self?.respond(fd, status: 200, body: Data(#"{"ok":true,"spoken":\#(spoken)}"#.utf8)) }
            }
            return
        case .typed, .turnStarted, .absorbed, .turnComplete, .undelivered, .title, .waiting, .checked, .shown:
            break
        }
        onEvent(event)
        respond(fd, status: 200, body: Data(#"{"ok":true}"#.utf8))
    }

    private func tick() {
        let now = Date()
        wake = nil
        touchParked(at: now)
        commands.tick(at: now)
        for refusal in commands.undeliverable(at: now) {
            onEvent(.undelivered(request: refusal.command.id, reason: refusal.reason.rawValue, handedOff: refusal.handedOff))
        }
        let expired = parked.filter { $0.deadline <= now }
        parked.removeAll { $0.deadline <= now }
        for p in expired { answer(p, with: []) }
        for session in Set(parked.flatMap { $0.members.map(\.session) }) { flush(session: session) }
        reschedule()
    }

    private func flush(session: String) {
        let now = Date()
        touchParked(at: now)
        var stillParked: [Parked] = []
        for var p in parked {
            guard p.members.contains(where: { $0.session == session }) else { stillParked.append(p); continue }
            var ready: [(Member, [AgentCommand])] = []
            for member in p.members where member.session == session {
                switch commands.poll(session: session, instance: member.instance, connection: p.connection, at: now) {
                case nil:
                    p.unknown.append(member.instance)
                    p.members.removeAll { $0 == member }
                case let found? where found.isEmpty: break
                case let found?: ready.append((member, found))
                }
            }
            if !p.shared, !p.unknown.isEmpty {
                respond(p.fd, status: 409)
            } else if ready.isEmpty && p.unknown.isEmpty {
                stillParked.append(p)
            } else {
                answer(p, with: ready)
            }
        }
        parked = stillParked
    }

    private func register(_ greeted: AgentEvent.Hello, filedUnder filed: String?, answering fd: Int32) {
        guard greeting.remove(fd) != nil else { return }
        guard admits(greeted.agent, greeted.installation) else { return respond(fd, status: 403) }
        var hello = greeted
        if let filed {
            sendBack(Set(filedByInstance.filter { $0.key != hello.instance && $0.value.id == filed }.keys))
            filedByInstance[hello.instance] = (filed, AgentSessionID.native(greeted.session))
            hello.session = filed
        } else {
            filedByInstance[hello.instance] = nil
        }
        agentByInstance[hello.instance] = hello.agent
        installationByInstance[hello.instance] = hello.installation
        sessionByInstance[hello.instance] = hello.session
        if hello.resumesAfterGap {
            for refusal in commands.connectionGap(session: hello.session, instance: hello.instance) {
                onEvent(.undelivered(request: refusal.command.id, reason: refusal.reason.rawValue, handedOff: refusal.handedOff))
            }
        }
        for refusal in commands.hello(session: hello.session, instance: hello.instance, connection: hello.connection ?? "", at: Date()) {
            onEvent(.undelivered(request: refusal.command.id, reason: refusal.reason.rawValue, handedOff: refusal.handedOff))
        }
        let earlier = parked.filter { $0.members.contains { $0.session == hello.session } }
        parked.removeAll { $0.members.contains { $0.session == hello.session } }
        for p in earlier { answer(p, with: []) }
        reschedule()
        if quiets(hello.session) {
            onEvent(.hello(hello.withoutContent))
            respond(fd, status: 200, body: Data(#"{"ok":true,"quiet":true}"#.utf8))
        } else {
            onEvent(.hello(hello))
            respond(fd, status: 200, body: Data(#"{"ok":true}"#.utf8))
        }
    }

    private func answer(_ p: Parked, with ready: [(Member, [AgentCommand])]) {
        let wire = ready.flatMap { member, commands in commands.map { $0.renamingSession { self.native(of: $0, on: member.instance) } } }
        let encoded = (try? AgentBridgeCodec.encode(wire)) ?? Data("[]".utf8)
        guard p.shared else { return respond(p.fd, status: 200, body: encoded) }
        let unknown = (try? JSONSerialization.data(withJSONObject: p.unknown)) ?? Data("[]".utf8)
        respond(p.fd, status: 200, body: Data(#"{"commands":"#.utf8) + encoded + Data(#","unknown":"#.utf8) + unknown + Data("}".utf8))
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
