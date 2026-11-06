import Foundation

enum ToolCLI {
    static func locate(
        named program: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        alsoIn: [String] = [],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let searched = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let usual = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"] + alsoIn
        return (searched + usual).map { ($0 as NSString).appendingPathComponent(program) }.first(where: isExecutable)
    }
    static func run(_ argv: [String], timeout: TimeInterval = 120, grace: TimeInterval = 2, environment: [String: String]? = nil) -> (Int32, String) {
        guard let program = argv.first else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = Array(argv.dropFirst())
        if let environment { process.environment = environment }
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = Output()
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
            return (-1, error.localizedDescription)
        }
        try? pipe.fileHandleForWriting.close()
        let command = argv.dropFirst().joined(separator: " ")
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + grace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + grace)
            }
            reader.readabilityHandler = nil
            return (-1, "\(command) did not finish within \(Int(timeout)) seconds")
        }
        if !output.waitForEnd(grace) { reader.readabilityHandler = nil }
        return (process.terminationStatus, output.text)
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let ended = DispatchSemaphore(value: 0)

        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        func finish() { ended.signal() }
        func waitForEnd(_ seconds: TimeInterval) -> Bool { ended.wait(timeout: .now() + seconds) == .success }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
