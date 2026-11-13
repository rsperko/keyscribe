import Foundation

public enum SpokenReplyCheck {
    public static let mismatchRate = 0.25
    public static let calibratedCheckers: Set<String> = ["parakeet-ultra"]

    public struct Result: Codable, Equatable, Sendable {
        public var heard: String
        public var errorRate: Double
        public var checker: String?

        public init(heard: String, errorRate: Double, checker: String? = nil) {
            self.heard = heard
            self.errorRate = errorRate
            self.checker = checker
        }

        public var matched: Bool { errorRate < SpokenReplyCheck.mismatchRate }
        public var calibrated: Bool { checker.map(SpokenReplyCheck.calibratedCheckers.contains) ?? false }
        public var percentHeard: Int { Int(((1 - min(max(errorRate, 0), 1)) * 100).rounded()) }
        public var checkerName: String? { checker.map { SpeechModelCatalog.entry(for: $0)?.displayName ?? $0 } }

        public var summary: String {
            matched
                ? "matched its text (\(percentHeard)% heard)"
                : "did not match its text (\(percentHeard)% heard)"
        }

        enum CodingKeys: String, CodingKey {
            case heard
            case errorRate = "error_rate"
            case checker
        }
    }

    public static func compare(text: String, normalized: String?, heard: String, checker: String? = nil) -> Result? {
        let expected = [text, normalized].compactMap { $0 }.map(letters).filter { !$0.isEmpty }
        guard !expected.isEmpty else { return nil }
        let said = letters(heard)
        let rate = expected.map { Double(BenchmarkScoring.editDistance($0, said)) / Double($0.count) }.min() ?? 1
        return Result(heard: heard, errorRate: rate, checker: checker)
    }

    static func letters(_ text: String) -> [String] {
        let joined = text.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        return BenchmarkScoring.tokens(spellingOutNumbers(joined)).joined().map(String.init)
    }

    private static let number = try! NSRegularExpression(pattern: #"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?"#)

    static func spellingOutNumbers(_ text: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .spellOut
        let source = text.replacingOccurrences(of: "%", with: " percent ") as NSString
        var spelled = ""
        var last = 0
        for match in number.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
            spelled += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let digits = source.substring(with: match.range)
            let value = Decimal(string: digits.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX"))
            spelled += " " + (value.flatMap { formatter.string(from: $0 as NSDecimalNumber) } ?? digits) + " "
            last = match.range.location + match.range.length
        }
        return spelled + source.substring(from: last)
    }
}

public struct SynthesisBaseline: Codable, Equatable, Sendable {
    public static let window = 40
    public static let minimumRenders = 5
    public static let shortestAudio: TimeInterval = 0.5

    public private(set) var perAudioSecond: [String: [Double]] = [:]

    public init() {}

    public mutating func record(_ stages: [SpokenAttempt.Detail], audioSeconds: Double) {
        guard audioSeconds >= Self.shortestAudio else { return }
        for stage in stages {
            guard let milliseconds = Double(stage.value) else { continue }
            perAudioSecond[stage.label, default: []].append(milliseconds / audioSeconds)
            if let count = perAudioSecond[stage.label]?.count, count > Self.window {
                perAudioSecond[stage.label]?.removeFirst(count - Self.window)
            }
        }
    }

    public func compare(_ stages: [SpokenAttempt.Detail], audioSeconds: Double) -> [RenderConditions.Stage] {
        stages.compactMap { stage in
            guard let milliseconds = Double(stage.value) else { return nil }
            let usual = perAudioSecond[stage.label].flatMap { $0.count >= Self.minimumRenders ? Self.median($0) : nil }
            return RenderConditions.Stage(stage: stage.label, milliseconds: milliseconds, usualMilliseconds: usual.map { $0 * audioSeconds })
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

public struct ActivityLog: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case recording = "dictation recording"
        case transcription = "speech recognition"
        case aiRequest = "an AI request"
    }

    private struct Span: Sendable {
        let id: Int
        let kind: Kind
        let start: Date
        var end: Date?
    }

    public static let keptFor: TimeInterval = 600

    private var spans: [Span] = []
    private var next = 0

    public init() {}

    public mutating func begin(_ kind: Kind, at now: Date) -> Int {
        spans.removeAll { span in span.end.map { now.timeIntervalSince($0) > Self.keptFor } ?? false }
        next += 1
        spans.append(Span(id: next, kind: kind, start: now))
        return next
    }

    public mutating func end(_ id: Int, at now: Date) {
        guard let index = spans.firstIndex(where: { $0.id == id }) else { return }
        spans[index].end = now
    }

    public func overlaps(from start: Date, to end: Date, now: Date) -> [Kind: TimeInterval] {
        var overlaps: [Kind: TimeInterval] = [:]
        for span in spans {
            let overlap = min(span.end ?? now, end).timeIntervalSince(max(span.start, start))
            if overlap > 0 { overlaps[span.kind, default: 0] += overlap }
        }
        return overlaps
    }
}

public struct RenderConditions: Equatable, Sendable {
    public struct Stage: Equatable, Sendable {
        public var stage: String
        public var milliseconds: Double
        public var usualMilliseconds: Double?

        public init(stage: String, milliseconds: Double, usualMilliseconds: Double?) {
            self.stage = stage
            self.milliseconds = milliseconds
            self.usualMilliseconds = usualMilliseconds
        }

        public var ratio: Double? {
            guard let usualMilliseconds, usualMilliseconds > 0 else { return nil }
            return milliseconds / usualMilliseconds
        }
    }

    public var appUptime: TimeInterval
    public var voiceUptime: TimeInterval?
    public var rendersSinceLoad: Int
    public var during: [ActivityLog.Kind: TimeInterval]
    public var thermal: String
    public var memoryPressure: String
    public var appMemoryMB: Int?
    public var loadAverage: Double?
    public var stages: [Stage]

    public init(
        appUptime: TimeInterval, voiceUptime: TimeInterval?, rendersSinceLoad: Int, during: [ActivityLog.Kind: TimeInterval],
        thermal: String, memoryPressure: String, appMemoryMB: Int?, loadAverage: Double?, stages: [Stage]
    ) {
        self.appUptime = appUptime
        self.voiceUptime = voiceUptime
        self.rendersSinceLoad = rendersSinceLoad
        self.during = during
        self.thermal = thermal
        self.memoryPressure = memoryPressure
        self.appMemoryMB = appMemoryMB
        self.loadAverage = loadAverage
        self.stages = stages
    }

    public var slowest: Stage? {
        stages.filter { $0.ratio != nil }.max { ($0.ratio ?? 0) < ($1.ratio ?? 0) }
    }

    public var details: [SpokenAttempt.Detail] {
        var details = [SpokenAttempt.Detail(label: "App running for", value: Self.duration(appUptime))]
        details.append(.init(
            label: "Voice loaded for",
            value: voiceUptime.map { "\(Self.duration($0)), \(rendersSinceLoad) render\(rendersSinceLoad == 1 ? "" : "s")" }
                ?? "loaded for this render"))
        let others = ActivityLog.Kind.allCases.compactMap { kind in
            during[kind].map { String(format: "%@ for %.1f s", kind.rawValue, $0) }
        }
        details.append(.init(
            label: "Also running during this render", value: others.isEmpty ? "nothing else in this app" : others.joined(separator: ", ")))
        details.append(.init(label: "Thermal state", value: thermal))
        details.append(.init(
            label: "Memory", value: "pressure \(memoryPressure)\(appMemoryMB.map { ", app using \($0) MB" } ?? "")"))
        if let loadAverage { details.append(.init(label: "Load average", value: String(format: "%.2f", loadAverage))) }
        if !stages.isEmpty {
            let timings = stages.map { stage -> String in
                let measured = "\(stage.stage) \(Int(stage.milliseconds.rounded())) ms"
                guard let usual = stage.usualMilliseconds, let ratio = stage.ratio else { return "\(measured) (no usual yet)" }
                return String(format: "%@ (usual %d, %.1f×)", measured, Int(usual.rounded()), ratio)
            }
            details.append(.init(label: "Stage timings vs this Mac's usual", value: timings.joined(separator: ", ")))
        }
        return details
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        guard minutes > 0 else { return "\(Int(seconds)) s" }
        let hours = minutes / 60
        guard hours > 0 else { return "\(minutes) min" }
        let days = hours / 24
        guard days > 0 else { return "\(hours) h \(minutes % 60) min" }
        return "\(days) d \(hours % 24) h"
    }
}

public struct SynthesisBaselineStore: Sendable {
    public let file: URL
    private static let lock = NSLock()

    public init(file: URL) {
        self.file = file
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public func load() -> SynthesisBaseline {
        Self.lock.withLock {
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SynthesisBaseline.self, from: $0) } ?? SynthesisBaseline()
        }
    }

    public func save(_ value: SynthesisBaseline) throws {
        try Self.lock.withLock {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(value).write(to: file, options: .atomic)
        }
    }
}

public struct SpokenReplyEvidence: Sendable {
    public struct File: Sendable {
        public var name: String
        public var data: Data
        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    public let dir: URL

    public init(dir: URL) {
        self.dir = dir
    }

    public func folder(entry: String, at: Date) -> URL {
        dir.appendingPathComponent(HistoryStore.todayString(date: at), isDirectory: true)
            .appendingPathComponent(entry, isDirectory: true)
    }

    public func isKept(entry: String, at: Date) -> Bool {
        FileManager.default.fileExists(atPath: folder(entry: entry, at: at).path)
    }

    @discardableResult
    public func save(entry: String, at: Date, files: [File]) throws -> URL {
        let folder = folder(entry: entry, at: at)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try file.data.write(to: folder.appendingPathComponent(file.name), options: .atomic)
        }
        return folder
    }

    public func addRender(entry: String, at: Date, wav: Data, report: Data) throws -> Int {
        let taken = renders(entry: entry, at: at).compactMap { Self.number(of: $0) }
        let number = (taken.max() ?? 1) + 1
        try save(entry: entry, at: at, files: [.init(name: "render \(number).wav", data: wav), .init(name: "render \(number) report.txt", data: report)])
        return number
    }

    public func renders(entry: String, at: Date) -> [URL] {
        let folder = folder(entry: entry, at: at)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("render ") && $0.hasSuffix(".wav") }
            .sorted { (Self.number(ofName: $0) ?? 0) < (Self.number(ofName: $1) ?? 0) }
            .map { folder.appendingPathComponent($0) }
    }

    public func original(entry: String, at: Date) -> URL? {
        let url = folder(entry: entry, at: at).appendingPathComponent("reply.wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func remove(entry: String, at: Date) throws {
        let folder = folder(entry: entry, at: at)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    public func removeDay(_ day: String) throws {
        let folder = dir.appendingPathComponent(day, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    public static func number(of url: URL) -> Int? { number(ofName: url.lastPathComponent) }

    static func number(ofName name: String) -> Int? {
        guard name.hasPrefix("render ") else { return name == "reply.wav" ? 1 : nil }
        return Int(name.dropFirst("render ".count).prefix { $0.isNumber })
    }
}
