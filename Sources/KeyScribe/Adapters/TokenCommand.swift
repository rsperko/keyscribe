import Foundation

enum TokenCommandError: Error, CustomStringConvertible, LocalizedError {
    case emptyCommand
    case emptyOutput
    case failed(Int32, message: String?)
    case timedOut

    var description: String {
        switch self {
        case .emptyCommand: "Token command is empty."
        case .emptyOutput: "Token command returned no token."
        case .failed(let status, let message):
            if let message, !message.isEmpty { "Token command failed (exit \(status)): \(message)" }
            else { "Token command failed with exit status \(status)." }
        case .timedOut: "Token command timed out."
        }
    }

    var errorDescription: String? { description }
}

struct ParsedToken: Equatable, Sendable {
    let token: String
    let expiresAt: Date?
    let expiresIn: TimeInterval?
}

enum TokenCommandOutput {
    static func token(from output: String) throws -> String {
        try parse(from: output).token
    }

    static func parse(from output: String) throws -> ParsedToken {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TokenCommandError.emptyOutput }
        if let json = jsonObject(from: trimmed), let token = jsonToken(from: json) {
            return ParsedToken(
                token: normalized(token),
                expiresAt: expiresAt(from: json),
                expiresIn: expiresIn(from: json))
        }
        guard let first = trimmed.split(whereSeparator: \.isNewline).first else {
            throw TokenCommandError.emptyOutput
        }
        return ParsedToken(token: normalized(String(first)), expiresAt: nil, expiresIn: nil)
    }

    private static func jsonObject(from output: String) -> [String: Any]? {
        guard output.first == "{", let data = output.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func jsonToken(from json: [String: Any]) -> String? {
        if let status = json["status"] as? [String: Any],
           let token = status["token"] as? String, !blank(token) {
            return token
        }
        for key in ["access_token", "token", "id_token"] {
            if let token = json[key] as? String, !blank(token) { return token }
        }
        return nil
    }

    private static func expiresAt(from json: [String: Any]) -> Date? {
        if let status = json["status"] as? [String: Any],
           let date = date(from: status["expirationTimestamp"]) {
            return date
        }
        for key in ["expires_at", "expiration", "expirationTimestamp"] {
            if let date = date(from: json[key]) { return date }
        }
        return nil
    }

    private static func expiresIn(from json: [String: Any]) -> TimeInterval? {
        guard let seconds = json["expires_in"] as? NSNumber else { return nil }
        return seconds.doubleValue
    }

    private static func date(from value: Any?) -> Date? {
        if let seconds = value as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        guard let string = value as? String, !blank(string) else { return nil }
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string)
    }

    private static func blank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalized(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "Bearer ", options: [.caseInsensitive, .anchored]) != nil {
            return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}

// In-memory token cache keyed by the command string, honoring the returned expiry (kubectl
// ExecCredential status.expirationTimestamp, OAuth expires_in, or a top-level expiration). Tokens
// without an expiry are cached for `defaultTTL` so a brokered credential is not re-minted on every
// rewrite — the command is in the hot path between hotkey-release and inserted text. The map is
// in-memory only, never persisted (a credential never touches disk).
actor TokenCommandCache {
    static let shared = TokenCommandCache()

    private struct Entry {
        let token: String
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let defaultTTL: TimeInterval = 300
    private let refreshSkew: TimeInterval = 30

    func token(forKey key: String, now: Date, run: @Sendable () async throws -> String) async throws -> String {
        if let entry = entries[key], entry.expiresAt.addingTimeInterval(-refreshSkew) > now {
            return entry.token
        }
        let parsed = try TokenCommandOutput.parse(from: try await run())
        let expiresAt: Date
        if let absolute = parsed.expiresAt {
            expiresAt = absolute
        } else if let relative = parsed.expiresIn {
            expiresAt = now.addingTimeInterval(relative)
        } else {
            expiresAt = now.addingTimeInterval(defaultTTL)
        }
        entries[key] = Entry(token: parsed.token, expiresAt: expiresAt)
        return parsed.token
    }

    func reset() { entries.removeAll() }
}

enum TokenCommandRunner {
    // Runs off the cooperative thread pool on a dedicated queue: the blocking Process wait must not
    // park a concurrency-pool thread. stdout and stderr are drained concurrently so a chatty command
    // (>64KB on either pipe) cannot deadlock against an unread buffer; stderr is surfaced on failure.
    private static let queue = DispatchQueue(label: "com.keyscribe.token-command", attributes: .concurrent)

    static func run(_ command: String, timeout: TimeInterval = 10) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try runBlocking(command, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func runBlocking(_ command: String, timeout: TimeInterval) throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TokenCommandError.emptyCommand }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", trimmed]
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let timedOut = Flag()
        let killer = DispatchWorkItem { timedOut.set(); process.terminate() }
        queue.asyncAfter(deadline: .now() + timeout, execute: killer)

        let stderrData = DataBox()
        let stderrReader = DispatchWorkItem {
            stderrData.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        }
        queue.async(execute: stderrReader)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        stderrReader.wait()

        if timedOut.value { throw TokenCommandError.timedOut }
        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData.value, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TokenCommandError.failed(
                process.terminationStatus, message: (message?.isEmpty == false) ? message : nil)
        }
        guard let output = String(data: stdoutData, encoding: .utf8) else {
            throw TokenCommandError.emptyOutput
        }
        return output
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.lock(); raised = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
