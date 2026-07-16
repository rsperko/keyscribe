import Darwin
import Foundation
import KeyScribeKit

enum TokenCommandError: Error, CustomStringConvertible, LocalizedError {
    case emptyCommand
    case emptyOutput
    case failed(Int32, message: String?)
    case timedOut
    case outputTooLarge

    var description: String {
        switch self {
        case .emptyCommand: "Token command is empty."
        case .emptyOutput: "Token command returned no token."
        case .failed(let status, let message):
            if let message, !message.isEmpty { "Token command failed (exit \(status)): \(message)" }
            else { "Token command failed with exit status \(status)." }
        case .timedOut: "Token command timed out."
        case .outputTooLarge: "Token command printed too much output to be a token."
        }
    }

    var errorDescription: String? { description }
}

// `description` keeps the stderr excerpt for ephemeral UI (a connection Test), where seeing what the command
// printed is the whole point of the button. The persisted/publicly-logged reason cannot: the command is
// user-supplied and a broker that echoes the token before failing would write credential material into
// history JSONL, against the "credential material is never persisted" invariant (KS-07 / LC-4).
extension TokenCommandError: RewriteFailureReporting {
    var rewriteFailureReason: String {
        switch self {
        case .emptyCommand: return "The token command is empty."
        case .emptyOutput: return "The token command returned no token."
        case .failed(let status, _): return "The token command failed (exit \(status))."
        case .timedOut: return "The token command timed out."
        case .outputTooLarge: return "The token command printed too much output to be a token."
        }
    }
}

struct ParsedToken: Equatable, Sendable {
    let token: String
    let expiresAt: Date?
    let expiresIn: TimeInterval?
}

enum TokenCommandOutput {
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

// Keyed by the command string, honoring the returned expiry (ExecCredential expirationTimestamp, OAuth
// expires_in, or a top-level expiration). No-expiry tokens are cached for `defaultTTL` so a brokered
// credential isn't re-minted on every rewrite. Never persisted — a credential never touches disk.
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
}

enum TokenCommandRunner {
    // Dedicated queue so the blocking Process wait doesn't park a concurrency-pool thread. stdout and
    // stderr are drained concurrently so a chatty command (>64KB on either pipe) can't deadlock against
    // an unread buffer.
    private static let queue = DispatchQueue(label: "com.keyscribe.token-command", attributes: .concurrent)

    static let stderrExcerptLimit = 300
    // Only a bounded diagnostic excerpt of stderr is ever used, so retain barely more than one.
    static let stderrCaptureLimit = 8 * 1024
    // stdout is the token. Any real credential is orders of magnitude under this, so exceeding it means the
    // command is not producing a token — fail rather than truncate, which would yield a corrupt credential.
    static let stdoutCaptureLimit = 1024 * 1024

    // Drain to EOF while retaining at most `limit` bytes. Draining MUST continue past the limit: the child
    // blocks once the ~64 KB pipe buffer fills, so bounding by "stop reading" would deadlock it instead —
    // the very hazard the concurrent readers exist to avoid. Bounding memory and draining are separate jobs.
    static func drain(_ handle: FileHandle, limit: Int) -> (data: Data, truncated: Bool) {
        var out = Data()
        var truncated = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return (out, truncated) }
            let room = limit - out.count
            if room <= 0 {
                truncated = true
            } else if chunk.count > room {
                out.append(chunk.prefix(room))
                truncated = true
            } else {
                out.append(chunk)
            }
        }
    }

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
        let killer = DispatchWorkItem {
            timedOut.set()
            process.terminate()
            queue.asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: killer)

        let stderrData = DataBox()
        let stderrReader = DispatchWorkItem {
            stderrData.set(drain(stderrPipe.fileHandleForReading, limit: stderrCaptureLimit).data)
        }
        queue.async(execute: stderrReader)

        let stdout = drain(stdoutPipe.fileHandleForReading, limit: stdoutCaptureLimit)
        process.waitUntilExit()
        killer.cancel()
        stderrReader.wait()

        if stdout.truncated { throw TokenCommandError.outputTooLarge }
        return try outcome(
            terminationStatus: process.terminationStatus, timedOut: timedOut.value,
            stdout: stdout.data, stderr: stderrData.value)
    }

    // A command that finished right as the deadline killer fired still produced a valid token, so exit 0
    // is success regardless of the timeout flag — only a non-zero exit is treated as a timeout.
    static func outcome(terminationStatus: Int32, timedOut: Bool, stdout: Data, stderr: Data) throws -> String {
        guard terminationStatus == 0 else {
            if timedOut { throw TokenCommandError.timedOut }
            // Bounded at capture: an unbounded excerpt rides the error into every consumer, and a chatty or
            // runaway command should not be able to size that (KS-07).
            let excerpt = String(data: stderr, encoding: .utf8).map {
                String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(stderrExcerptLimit))
            }
            throw TokenCommandError.failed(
                terminationStatus, message: (excerpt?.isEmpty == false) ? excerpt : nil)
        }
        guard let output = String(data: stdout, encoding: .utf8) else {
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
