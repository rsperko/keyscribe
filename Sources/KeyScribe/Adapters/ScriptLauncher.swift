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

    static func run(program: String, arguments: [String], reportWithin window: TimeInterval = reportWindow) async -> ScriptRun {
        let path = expandedPath(program)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else { return .notRunnable }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors

        return await withCheckedContinuation { continuation in
            let report = Report(continuation)
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
        private var errorOutput = Data()
        private var status: Int32?
        private var closed = false

        init(_ continuation: CheckedContinuation<ScriptRun, Never>) {
            self.continuation = continuation
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
            DispatchQueue.global().asyncAfter(deadline: .now() + ScriptLauncher.errorGrace) { self.windowClosed() }
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

        private func finishIfExited() {
            let result: ScriptRun? = lock.withLock {
                guard closed, let status else { return nil }
                return .finished(status: status, lastError: ScriptLauncher.lastLine(of: errorOutput))
            }
            if let result { resume(result) }
        }

        private func resume(_ result: ScriptRun) {
            let pending: CheckedContinuation<ScriptRun, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: result)
        }
    }
}
