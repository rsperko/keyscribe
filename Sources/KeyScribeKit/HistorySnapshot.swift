import Foundation

public struct HistorySnapshot: Sendable {
    public struct Reference: Hashable, Sendable {
        public let dayFile: String
        public let line: Int
    }

    public struct Item: Sendable {
        public let reference: Reference
        public let entry: HistoryEntry
    }

    public struct Fingerprint: Hashable, Sendable {
        let files: [String: Int]
        var unreadable: Set<String> = []
    }

    public let items: [Item]
    public let unreadableLines: Int
    public var unreadableFiles = 0
    public let fingerprint: Fingerprint
}

extension HistoryStore {
    public func snapshot() throws -> HistorySnapshot {
        try Task.checkCancellation()
        let (files, unreadableFiles) = readAllDayFiles()
        var items: [HistorySnapshot.Item] = []
        var unreadable = 0
        for (name, data) in files {
            try Task.checkCancellation()
            for (line, bytes) in Self.lines(data).enumerated() where !bytes.isEmpty {
                if let entry = try? HistoryEntry(jsonLine: String(decoding: bytes, as: UTF8.self)) {
                    items.append(.init(reference: .init(dayFile: name, line: line), entry: entry))
                } else {
                    unreadable += 1
                }
            }
        }
        return HistorySnapshot(
            items: items, unreadableLines: unreadable, unreadableFiles: unreadableFiles.count,
            fingerprint: Self.fingerprint(of: files, unreadable: unreadableFiles))
    }

    public func fingerprint() -> HistorySnapshot.Fingerprint {
        let (files, unreadable) = readAllDayFiles()
        return Self.fingerprint(of: files, unreadable: unreadable)
    }

    private func readAllDayFiles() -> (files: [(String, Data)], unreadable: Set<String>) {
        Self.mutationQueue.sync {
            var files: [(String, Data)] = []
            var unreadable = Set<String>()
            for name in dayFiles() {
                if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) {
                    files.append((name, data))
                } else {
                    unreadable.insert(name)
                }
            }
            return (files, unreadable)
        }
    }

    private static func fingerprint(of files: [(String, Data)], unreadable: Set<String>) -> HistorySnapshot.Fingerprint {
        var hashes: [String: Int] = [:]
        for (name, data) in files {
            var hasher = Hasher()
            hasher.combine(data)
            hashes[name] = hasher.finalize()
        }
        return .init(files: hashes, unreadable: unreadable)
    }

    private static func lines(_ data: Data) -> [Data] {
        var result = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if result.last?.isEmpty == true { result.removeLast() }
        return result.map { Data($0) }
    }
}
