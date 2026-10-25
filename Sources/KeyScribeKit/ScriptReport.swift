import Foundation

public struct ScriptReport: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        case done
        case info
    }

    public struct Message: Equatable, Sendable {
        public var level: Level
        public var text: String

        public init(level: Level, text: String) {
            self.level = level
            self.text = text
        }
    }

    public struct Option: Equatable, Sendable {
        public var value: String
        public var label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    public static let textLimit = 200
    static let donePrefix = "::done::"
    static let infoPrefix = "::info::"
    static let choicePrefix = "::choice::"

    public var message: Message?
    public var options: [Option]

    public init(message: Message? = nil, options: [Option] = []) {
        self.message = message
        self.options = options
    }

    mutating func read(_ line: Substring) {
        let line = line.trimmingCharacters(in: .newlines)
        if line.hasPrefix(Self.donePrefix) {
            setMessage(.done, String(line.dropFirst(Self.donePrefix.count)))
        } else if line.hasPrefix(Self.infoPrefix) {
            setMessage(.info, String(line.dropFirst(Self.infoPrefix.count)))
        } else if line.hasPrefix(Self.choicePrefix) {
            addOption(String(line.dropFirst(Self.choicePrefix.count)))
        }
    }

    private mutating func setMessage(_ level: Level, _ raw: String) {
        let text = Self.shortened(raw.trimmingCharacters(in: .whitespaces))
        guard !text.isEmpty else { return }
        message = Message(level: level, text: text)
    }

    private mutating func addOption(_ raw: String) {
        let parts = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        let value = parts[0].trimmingCharacters(in: .whitespaces)
        let label = Self.shortened((parts.count > 1 ? String(parts[1]) : value).trimmingCharacters(in: .whitespaces))
        guard !value.isEmpty, !label.isEmpty, options.count < Collector.optionLimit,
              !options.contains(where: { $0.value == value }) else { return }
        options.append(Option(value: value, label: label))
    }

    private static func shortened(_ text: String) -> String {
        text.count > textLimit ? String(text.prefix(textLimit)) + "\u{2026}" : text
    }

    public struct Collector: Sendable {
        public static let lineLimit = 4_096
        static let optionLimit = 64

        private var report = ScriptReport()
        private var pending = Data()
        private var overflowing = false

        public init() {}

        public mutating func append(_ data: Data) {
            var rest = data[...]
            while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
                take(rest[rest.startIndex..<newline])
                endLine()
                rest = rest[rest.index(after: newline)...]
            }
            take(rest)
        }

        public mutating func finish() -> ScriptReport {
            endLine()
            return report
        }

        private mutating func take(_ bytes: Data.SubSequence) {
            guard !overflowing else { return }
            if pending.count + bytes.count > Self.lineLimit {
                overflowing = true
                pending.removeAll()
            } else {
                pending.append(contentsOf: bytes)
            }
        }

        private mutating func endLine() {
            if !overflowing, pending.first == UInt8(ascii: ":") {
                report.read(String(decoding: pending, as: UTF8.self)[...])
            }
            pending.removeAll(keepingCapacity: true)
            overflowing = false
        }
    }
}
