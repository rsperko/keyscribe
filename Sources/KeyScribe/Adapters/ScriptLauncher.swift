import Foundation

enum ScriptLauncher {
    static let reportWindow: TimeInterval = 1.5
    static let errorGrace: TimeInterval = 0.25
    static let errorCaptureLimit = 16_384
    static let errorLineLimit = 200

    private static let running = Running()

    static func expandedPath(_ program: String) -> String {
        (program as NSString).expandingTildeInPath
    }

    static func run(
        program: String, arguments: [String], input: String? = nil, reportWithin window: TimeInterval = reportWindow,
        onLateFinish: @escaping @Sendable (ScriptRun) -> Void = { _ in }
    ) async -> ScriptRun {
        let path = expandedPath(program)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else { return .notRunnable }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors

        return await withCheckedContinuation { continuation in
            let report = Report(continuation, onLateFinish: onLateFinish)
            errors.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    report.errorsClosed()
                } else {
                    report.append(data)
                }
            }
            process.terminationHandler = { finished in
                running.remove(finished)
                report.exited(finished.terminationStatus)
            }
            running.insert(process)
            do {
                try process.run()
            } catch {
                running.remove(process)
                errors.fileHandleForReading.readabilityHandler = nil
                report.failedToStart(error.localizedDescription)
                return
            }
            if let stdin, let input {
                let writer = stdin.fileHandleForWriting
                _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                DispatchQueue.global().async {
                    try? writer.write(contentsOf: Data(input.utf8))
                    try? writer.close()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + window) { report.windowClosed() }
        }
    }

    static func lastLine(of data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) else { return nil }
        return line.count > errorLineLimit ? String(line.prefix(errorLineLimit)) + "\u{2026}" : line
    }

    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [ObjectIdentifier: Process] = [:]

        func insert(_ process: Process) { lock.withLock { processes[ObjectIdentifier(process)] = process } }
        func remove(_ process: Process) { _ = lock.withLock { processes.removeValue(forKey: ObjectIdentifier(process)) } }
    }

    private final class Report: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ScriptRun, Never>?
        private var onLateFinish: (@Sendable (ScriptRun) -> Void)?
        private var reportedRunning = false
        private var errorOutput = Data()
        private var status: Int32?
        private var closed = false

        init(_ continuation: CheckedContinuation<ScriptRun, Never>, onLateFinish: @escaping @Sendable (ScriptRun) -> Void) {
            self.continuation = continuation
            self.onLateFinish = onLateFinish
        }

        func append(_ data: Data) {
            lock.withLock {
                errorOutput.append(data.suffix(ScriptLauncher.errorCaptureLimit))
                let excess = errorOutput.count - ScriptLauncher.errorCaptureLimit
                if excess > 0 { errorOutput.removeFirst(excess) }
            }
        }

        func errorsClosed() {
            lock.withLock { closed = true }
            finishIfExited()
        }

        func exited(_ status: Int32) {
            lock.withLock { self.status = status }
            finishIfExited()
            DispatchQueue.global().asyncAfter(deadline: .now() + ScriptLauncher.errorGrace) { self.graceEnded() }
        }

        func failedToStart(_ reason: String) {
            resume(.couldNotStart(reason))
        }

        func windowClosed() {
            let result: ScriptRun = lock.withLock {
                status.map { .finished(status: $0, lastError: ScriptLauncher.lastLine(of: errorOutput)) } ?? .stillRunning
            }
            resume(result)
        }

        private func graceEnded() {
            let result: ScriptRun? = lock.withLock {
                status.map { .finished(status: $0, lastError: ScriptLauncher.lastLine(of: errorOutput)) }
            }
            if let result { resume(result) }
        }

        private func finishIfExited() {
            let result: ScriptRun? = lock.withLock {
                guard closed, let status else { return nil }
                return .finished(status: status, lastError: ScriptLauncher.lastLine(of: errorOutput))
            }
            if let result { resume(result) }
        }

        private func resume(_ result: ScriptRun) {
            let (pending, late): (CheckedContinuation<ScriptRun, Never>?, (@Sendable (ScriptRun) -> Void)?) = lock.withLock {
                if let continuation {
                    self.continuation = nil
                    if result == .stillRunning { reportedRunning = true } else { onLateFinish = nil }
                    return (continuation, nil)
                }
                guard reportedRunning, result != .stillRunning, let handler = onLateFinish else { return (nil, nil) }
                onLateFinish = nil
                return (nil, handler)
            }
            pending?.resume(returning: result)
            late?(result)
        }
    }
}
