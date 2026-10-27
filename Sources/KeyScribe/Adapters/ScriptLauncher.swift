import Foundation
import KeyScribeKit

enum ScriptLauncher {
    static let reportWindow: TimeInterval = 1.5
    static let errorGrace: TimeInterval = 0.25
    static let errorCaptureLimit = 16_384
    static let errorLineLimit = 200
    static let choiceVariable = "KEYSCRIBE_CHOICE"

    private static let running = Running()

    static func expandedPath(_ program: String) -> String {
        (program as NSString).expandingTildeInPath
    }

    static func resolvedPath(_ program: String) -> String? {
        guard !program.isEmpty else { return nil }
        return URL(fileURLWithPath: expandedPath(program)).resolvingSymlinksInPath().path
    }

    static func run(
        program: String, arguments: [String], input: String? = nil, environment: [String: String] = [:],
        reportWithin window: TimeInterval = reportWindow,
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
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let errors = Pipe()
        process.standardError = errors

        return await withCheckedContinuation { continuation in
            let report = Report(continuation, onLateFinish: onLateFinish)
            errors.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    report.streamClosed()
                } else {
                    report.appendError(data)
                }
            }
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    report.streamClosed()
                } else {
                    report.appendOutput(data)
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
                output.fileHandleForReading.readabilityHandler = nil
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

    // Only the error-code form an Apple Event failure prints, on an error line of a process that failed: a number
    // elsewhere in the output, or a generic permission error, says nothing about Automation.
    // The denial line is kept over any later line, since it names the app that refused.
    static func error(in data: Data, status: Int32) -> ScriptError? {
        guard let line = lastLine(of: data) else { return nil }
        guard status != 0 else { return ScriptError(line: line) }
        let denial = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last { line in
            line.contains("(-1743)") && line.range(of: #"\berror\b|not authorized"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        guard let denial, let denied = lastLine(of: Data(denial.utf8)) else { return ScriptError(line: line) }
        return ScriptError(line: denied, blocksAutomation: true)
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
        private var output = ScriptReport.Collector()
        private var status: Int32?
        private var openStreams = 2

        init(_ continuation: CheckedContinuation<ScriptRun, Never>, onLateFinish: @escaping @Sendable (ScriptRun) -> Void) {
            self.continuation = continuation
            self.onLateFinish = onLateFinish
        }

        func appendOutput(_ data: Data) {
            lock.withLock { output.append(data) }
        }

        func appendError(_ data: Data) {
            lock.withLock {
                errorOutput.append(data.suffix(ScriptLauncher.errorCaptureLimit))
                let excess = errorOutput.count - ScriptLauncher.errorCaptureLimit
                if excess > 0 { errorOutput.removeFirst(excess) }
            }
        }

        func streamClosed() {
            lock.withLock { openStreams -= 1 }
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
            guard lock.withLock({ status == nil }) else { return }
            resume(.stillRunning)
        }

        private func graceEnded() {
            let result: ScriptRun? = lock.withLock { status.map(finished) }
            if let result { resume(result) }
        }

        private func finishIfExited() {
            let result: ScriptRun? = lock.withLock {
                guard openStreams == 0, let status else { return nil }
                return finished(status)
            }
            if let result { resume(result) }
        }

        private func finished(_ status: Int32) -> ScriptRun {
            var collected = output
            return .finished(status: status, lastError: ScriptLauncher.error(in: errorOutput, status: status), report: collected.finish())
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
