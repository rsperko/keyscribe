import Darwin
import Foundation

public enum HostCLI {
    public struct Output: Equatable, Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: String
        public var truncated: Bool
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case couldNotStart(String)
        case timedOut(String)
        case cancelled(String)

        public var description: String {
            switch self {
            case .couldNotStart(let subcommand): "\(subcommand) could not start"
            case .timedOut(let subcommand): "\(subcommand) did not finish in time"
            case .cancelled(let subcommand): "\(subcommand) was cancelled"
            }
        }
    }

    public static func run(
        _ argv: [String], subcommand: String, input: Data? = nil, environment: [String: String]? = nil,
        timeout: Duration = .seconds(5), grace: Duration = .seconds(1), limit: Int = 1 << 20
    ) async throws -> Output {
        let child = Child()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    let result = child.run(
                        argv, input: input, environment: environment, timeout: timeout.seconds, grace: grace.seconds, limit: limit)
                    switch result {
                    case .finished(let output): continuation.resume(returning: output)
                    case .couldNotStart: continuation.resume(throwing: Failure.couldNotStart(subcommand))
                    case .timedOut: continuation.resume(throwing: Failure.timedOut(subcommand))
                    case .cancelled: continuation.resume(throwing: Failure.cancelled(subcommand))
                    }
                }
            }
        } onCancel: {
            child.cancel()
        }
    }

    private enum Result {
        case finished(Output)
        case couldNotStart
        case timedOut
        case cancelled
    }

    private final class Child: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }
        private var isCancelled: Bool { lock.withLock { cancelled } }

        func run(_ argv: [String], input: Data?, environment: [String: String]?, timeout: Double, grace: Double, limit: Int) -> Result {
            guard let program = argv.first, program.hasPrefix("/"), !isCancelled else { return isCancelled ? .cancelled : .couldNotStart }
            var outPipe: [Int32] = [-1, -1]
            var errPipe: [Int32] = [-1, -1]
            var inPipe: [Int32] = [-1, -1]
            guard pipe(&outPipe) == 0 else { return .couldNotStart }
            guard pipe(&errPipe) == 0 else {
                outPipe.forEach { close($0) }
                return .couldNotStart
            }
            if input != nil, pipe(&inPipe) != 0 {
                (outPipe + errPipe).forEach { close($0) }
                return .couldNotStart
            }
            let pid = spawn(argv, environment: environment, stdin: input != nil ? inPipe[0] : nil, stdout: outPipe[1], stderr: errPipe[1])
            close(outPipe[1])
            close(errPipe[1])
            if input != nil { close(inPipe[0]) }
            guard let pid else {
                close(outPipe[0])
                close(errPipe[0])
                if input != nil { close(inPipe[1]) }
                return .couldNotStart
            }
            if let input { feed(input, to: inPipe[1]) }
            return collect(pid: pid, out: outPipe[0], err: errPipe[0], timeout: timeout, grace: grace, limit: limit)
        }

        private func spawn(_ argv: [String], environment: [String: String]?, stdin: Int32?, stdout: Int32, stderr: Int32) -> pid_t? {
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attributes)
            defer {
                posix_spawn_file_actions_destroy(&actions)
                posix_spawnattr_destroy(&attributes)
            }
            if let stdin {
                posix_spawn_file_actions_adddup2(&actions, stdin, 0)
            } else {
                posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            }
            posix_spawn_file_actions_adddup2(&actions, stdout, 1)
            posix_spawn_file_actions_adddup2(&actions, stderr, 2)
            posix_spawn_file_actions_addchdir_np(&actions, FileManager.default.homeDirectoryForCurrentUser.path)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
            posix_spawnattr_setpgroup(&attributes, 0)
            let arguments = argv.map { strdup($0) } + [nil]
            let variables = environment.map { $0.map { strdup("\($0.key)=\($0.value)") } + [nil] }
            defer {
                arguments.forEach { free($0) }
                variables?.forEach { free($0) }
            }
            var pid: pid_t = 0
            let status = variables.map { posix_spawn(&pid, argv[0], &actions, &attributes, arguments, $0) }
                ?? posix_spawn(&pid, argv[0], &actions, &attributes, arguments, environ)
            return status == 0 ? pid : nil
        }

        private func feed(_ input: Data, to fd: Int32) {
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            Thread.detachNewThread {
                input.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                        if written < 0 { if errno == EINTR { continue } else { break } }
                        offset += written
                    }
                }
                close(fd)
            }
        }

        private func collect(pid: pid_t, out: Int32, err: Int32, timeout: Double, grace: Double, limit: Int) -> Result {
            var streams = [out: Data(), err: Data()]
            var open: Set<Int32> = [out, err]
            var truncated = false
            var status: Int32?
            var exitedAt: Date?
            let deadline = Date().addingTimeInterval(timeout)
            var buffer = [UInt8](repeating: 0, count: 65536)
            defer { [out, err].forEach { close($0) } }
            while true {
                if isCancelled {
                    stop(pid, grace: grace, exited: status != nil)
                    return .cancelled
                }
                if status == nil, Date() >= deadline {
                    stop(pid, grace: grace, exited: false)
                    return .timedOut
                }
                if status == nil, let reaped = reap(pid) {
                    status = reaped
                    exitedAt = Date()
                }
                if status != nil, open.isEmpty || Date().timeIntervalSince(exitedAt ?? Date()) >= grace { break }
                var polled = open.sorted().map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
                if polled.isEmpty {
                    usleep(10_000)
                    continue
                }
                guard poll(&polled, nfds_t(polled.count), 50) > 0 else { continue }
                for entry in polled where entry.revents != 0 {
                    let count = read(entry.fd, &buffer, buffer.count)
                    if count > 0 {
                        let room = max(0, limit - (streams[entry.fd]?.count ?? 0))
                        if count > room { truncated = true }
                        streams[entry.fd]?.append(contentsOf: buffer[0..<min(count, room)])
                    } else if count == 0 || errno != EINTR {
                        open.remove(entry.fd)
                    }
                }
            }
            killpg(pid, SIGKILL)
            return .finished(Output(
                status: status ?? -1, stdout: streams[out] ?? Data(), stderr: String(decoding: streams[err] ?? Data(), as: UTF8.self),
                truncated: truncated || !open.isEmpty))
        }

        private func reap(_ pid: pid_t) -> Int32? {
            var raw: Int32 = 0
            guard waitpid(pid, &raw, WNOHANG) == pid else { return nil }
            return raw & 0x7f == 0 ? (raw >> 8) & 0xff : -1
        }

        private func stop(_ pid: pid_t, grace: Double, exited: Bool) {
            killpg(pid, SIGTERM)
            let until = Date().addingTimeInterval(grace)
            var reaped = exited
            while !reaped, Date() < until {
                reaped = reap(pid) != nil
                if !reaped { usleep(10_000) }
            }
            killpg(pid, SIGKILL)
            if !reaped {
                Thread.detachNewThread {
                    var raw: Int32 = 0
                    _ = waitpid(pid, &raw, 0)
                }
            }
        }
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
