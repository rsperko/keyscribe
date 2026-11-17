import Foundation
import KeyScribeKit

enum ToolCLI {
    struct Ran: Sendable {
        var end: ToolRunEnd
        var output: Data
        var text: String { String(decoding: output, as: UTF8.self) }
    }

    static func run(_ argv: [String], timeout: TimeInterval = 120, grace: TimeInterval = 2, environment: [String: String]? = nil) -> (Int32, String) {
        let ran = execute(argv, timeout: timeout, grace: grace, environment: environment)
        switch ran.end {
        case .exited(let status): return (status, ran.text)
        case .signaled(let signal): return (128 + signal, ran.text)
        case .timedOut: return (-1, "\(argv.dropFirst().joined(separator: " ")) did not finish within \(Int(timeout)) seconds")
        case .couldNotStart(let reason): return (-1, reason)
        }
    }

    static func execute(
        _ argv: [String], timeout: TimeInterval, grace: TimeInterval = 2, environment: [String: String]? = nil, includeErrors: Bool = true,
        limit: Int = .max
    ) -> Ran {
        guard let program = argv.first else { return Ran(end: .couldNotStart("No command."), output: Data()) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = Array(argv.dropFirst())
        if let environment { process.environment = environment }
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = includeErrors ? pipe : FileHandle.nullDevice
        let output = Output(limit: limit)
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                output.finish()
            } else {
                output.append(chunk)
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            try? pipe.fileHandleForWriting.close()
            return Ran(end: .couldNotStart(error.localizedDescription), output: Data())
        }
        try? pipe.fileHandleForWriting.close()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + grace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + grace)
            }
            reader.readabilityHandler = nil
            return Ran(end: .timedOut(Int(timeout.rounded())), output: output.data)
        }
        if !output.waitForEnd(grace) { reader.readabilityHandler = nil }
        let end: ToolRunEnd = process.terminationReason == .uncaughtSignal ? .signaled(process.terminationStatus) : .exited(process.terminationStatus)
        return Ran(end: end, output: output.data)
    }

    static func executeGrouped(
        _ argv: [String], timeout: TimeInterval, environment: [String: String], includeErrors: Bool, limit: Int, grace: TimeInterval = 1
    ) -> Ran {
        guard let program = argv.first else { return Ran(end: .couldNotStart("No command."), output: Data()) }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return Ran(end: .couldNotStart(String(cString: strerror(errno))), output: Data()) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        if includeErrors {
            posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_addchdir_np(&actions, FileManager.default.homeDirectoryForCurrentUser.path)
        let arguments = argv.map { strdup($0) } + [nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (arguments + variables).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, program, &actions, &attributes, arguments, variables)
        close(fds[1])
        guard spawned == 0 else {
            close(fds[0])
            return Ran(end: .couldNotStart(String(cString: strerror(spawned))), output: Data())
        }
        let output = Output(limit: limit)
        let reader = GroupReader(fd: fds[0], output: output)
        Thread.detachNewThread { reader.run() }
        var status: Int32 = 0
        func reaped(within seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            repeat {
                if waitpid(pid, &status, WNOHANG) == pid { return true }
                usleep(20_000)
            } while Date() < deadline
            return false
        }
        var end: ToolRunEnd
        if reaped(within: timeout) {
            let signal = status & 0x7f
            end = signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
            kill(-pid, SIGTERM)
        } else {
            kill(-pid, SIGTERM)
            if !reaped(within: grace) {
                kill(-pid, SIGKILL)
                _ = reaped(within: grace)
            }
            kill(-pid, SIGKILL)
            end = .timedOut(Int(timeout.rounded()))
        }
        reader.finish(within: grace)
        return Ran(end: end, output: output.data)
    }

    private final class GroupReader: @unchecked Sendable {
        private let fd: Int32
        private let output: Output
        private let lock = NSLock()
        private var stopped = false
        private let done = DispatchSemaphore(value: 0)

        init(fd: Int32, output: Output) {
            self.fd = fd
            self.output = output
        }

        func run() {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while !lock.withLock({ stopped }) {
                guard poll(&poller, 1, 100) > 0 else { continue }
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                output.append(Data(buffer[0..<count]))
            }
            close(fd)
            done.signal()
        }

        func finish(within seconds: TimeInterval) {
            if done.wait(timeout: .now() + seconds) == .success { return }
            lock.withLock { stopped = true }
            _ = done.wait(timeout: .now() + 1)
        }
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var kept = Data()
        private let ended = DispatchSemaphore(value: 0)
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        func append(_ chunk: Data) {
            lock.withLock {
                guard kept.count < limit else { return }
                kept.append(chunk.prefix(limit - kept.count))
            }
        }
        func finish() { ended.signal() }
        func waitForEnd(_ seconds: TimeInterval) -> Bool { ended.wait(timeout: .now() + seconds) == .success }
        var data: Data { lock.withLock { kept } }
    }
}
