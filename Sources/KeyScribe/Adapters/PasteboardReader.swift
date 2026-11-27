import AppKit
import Foundation

enum PasteboardReader {
    static let flag = "--read-pasteboard"
    static let childLifetimeSeconds: UInt32 = 30

    nonisolated(unsafe) static var helper: URL?

    struct Reading {
        let changeCount: Int
        let text: String?
        let items: [[NSPasteboard.PasteboardType: Data]]?
    }

    enum Outcome {
        case read(Reading)
        case couldNotStart
        case unreadable
    }

    static func warm() {
        guard let helper else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = helper
            process.arguments = [flag]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
        }
    }

    static func serveIfAsked(_ arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: flag) else { return }
        guard index + 2 < arguments.count, let maxBytes = Int(arguments[index + 2]) else { exit(2) }
        alarm(childLifetimeSeconds)
        serve(NSPasteboard(name: NSPasteboard.Name(arguments[index + 1])), maxBytes: maxBytes, to: .standardOutput)
        exit(0)
    }

    private static func serve(_ pb: NSPasteboard, maxBytes: Int, to out: FileHandle) {
        var header: [String: Any] = ["changeCount": pb.changeCount]
        header["text"] = pb.string(forType: .string)
        send(header, to: out)
        var total = 0
        var items: [[String: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var byType: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                guard total <= maxBytes else { return }
                byType[type.rawValue] = data
            }
            items.append(byType)
        }
        send(["items": items], to: out)
    }

    private static func send(_ frame: [String: Any], to out: FileHandle) {
        guard let body = try? PropertyListSerialization.data(fromPropertyList: frame, format: .binary, options: 0) else { return }
        var length = UInt32(body.count).bigEndian
        try? out.write(contentsOf: Data(bytes: &length, count: 4) + body)
    }

    static func read(
        _ name: NSPasteboard.Name, maxBytes: Int, deadline: ContinuousClock.Instant, helper: URL
    ) async -> Outcome {
        let process = Process()
        process.executableURL = helper
        process.arguments = [flag, name.rawValue, String(maxBytes)]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.insertion.error("could not start the clipboard reader: \(error.localizedDescription, privacy: .public)")
            return .couldNotStart
        }
        try? out.fileHandleForWriting.close()
        let frames = Frames()
        let reader = out.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            while case let chunk = reader.availableData, !chunk.isEmpty { frames.append(chunk) }
            frames.finish(.endOfOutput)
        }
        let left = ContinuousClock.now.duration(to: deadline)
        let seconds = max(0, Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { frames.finish(.deadline) }
        let ending = await withTaskCancellationHandler {
            await frames.ended()
        } onCancel: {
            frames.finish(.cancelled)
        }
        if ending != .endOfOutput {
            kill(process.processIdentifier, SIGKILL)
            if ending == .deadline { Log.insertion.notice("clipboard read outlasted its budget") }
        }
        guard let reading = frames.reading() else {
            guard ending != .endOfOutput else {
                Log.insertion.error("the clipboard reader exited without an answer")
                return .couldNotStart
            }
            return .unreadable
        }
        return .read(reading)
    }

    private enum Ending { case endOfOutput, deadline, cancelled }

    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var decoded: [[String: Any]?] = []
        private var ending: Ending?
        private var waiter: CheckedContinuation<Ending, Never>?

        func append(_ chunk: Data) {
            let frames = lock.withLock { () -> [Data] in
                guard ending == nil else { return [] }
                buffer.append(chunk)
                var frames: [Data] = []
                while buffer.count >= 4 {
                    let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                    guard buffer.count >= 4 + length else { break }
                    let start = buffer.startIndex + 4
                    frames.append(buffer.subdata(in: start ..< start + length))
                    buffer = buffer.subdata(in: start + length ..< buffer.endIndex)
                }
                return frames
            }
            guard !frames.isEmpty else { return }
            let read = frames.map { (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any] }
            lock.withLock { decoded += read }
        }

        func finish(_ how: Ending) {
            let resumed = lock.withLock { () -> (CheckedContinuation<Ending, Never>, Ending)? in
                guard ending == nil else { return nil }
                ending = how
                defer { waiter = nil }
                return waiter.map { ($0, how) }
            }
            resumed.map { $0.0.resume(returning: $0.1) }
        }

        func ended() async -> Ending {
            await withCheckedContinuation { continuation in
                let already = lock.withLock { () -> Ending? in
                    if let ending { return ending }
                    waiter = continuation
                    return nil
                }
                if let already { continuation.resume(returning: already) }
            }
        }

        func reading() -> Reading? {
            let frames = lock.withLock { decoded }
            guard let header = frames.first ?? nil, let changeCount = header["changeCount"] as? Int else { return nil }
            let body = frames.dropFirst().first ?? nil
            let items = (body?["items"] as? [[String: Data]])?.map { byType in
                Dictionary(uniqueKeysWithValues: byType.map { (NSPasteboard.PasteboardType($0.key), $0.value) })
            }
            return Reading(changeCount: changeCount, text: header["text"] as? String, items: items)
        }
    }
}
