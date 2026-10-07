import Foundation

// Relative, never an absolute floor: a quiet mic must still win once it speaks. A challenger only has to outlast a
// short sustain, but a channel earns pause protection (its held peak) only from a level that lasted the much longer
// hold-qualify window, so a click or a brief bump can win a moment of the take and never keep it.
public struct ChannelSelector: Sendable {
    public struct SwitchRecord: Sendable, Equatable {
        public let atSeconds: Double
        public let from: Int
        public let to: Int
        public let levels: [Float]
    }

    public static let defaultSwitchMarginDB: Float = 6
    public static let defaultSwitchSustainSeconds = 0.05
    public static let defaultAttackSeconds = 0.01
    public static let defaultReleaseSeconds = 0.3
    public static let peakHoldDecaySeconds = 3.0
    public static let holdQualifySeconds = 0.3
    public static let switchHistoryCapacity = 8
    private static let windowBins = 8
    private static let minimumSustainBuffers = 2

    public private(set) var selected: Int
    public private(set) var switchCount = 0
    public private(set) var levels: [Float]
    public private(set) var peakLevels: [Float]
    public private(set) var switches: [SwitchRecord] = []

    private let sampleRate: Double
    private let pinned: Int?
    private let switchRatio: Float
    private let switchSustainSeconds: Double
    private let attackSeconds: Double
    private let releaseSeconds: Double
    private var fast: [Float]
    private var lastFast: [Float]
    private var held: [Float]
    private var sustained: [Float]
    private var sustainWindow: WindowMinimum
    private var qualifyWindow: WindowMinimum
    private var candidate = -1
    private var candidateSeconds = 0.0
    private var candidateBuffers = 0
    private var elapsedSeconds = 0.0
    private var primed = false

    public init(channelCount: Int, sampleRate: Double, pinned: Int? = nil,
                switchMarginDB: Float = defaultSwitchMarginDB,
                switchSustainSeconds: Double = defaultSwitchSustainSeconds,
                attackSeconds: Double = defaultAttackSeconds,
                releaseSeconds: Double = defaultReleaseSeconds) {
        let count = max(1, channelCount)
        self.sampleRate = sampleRate
        self.pinned = pinned.map { min(max(0, $0), count - 1) }
        self.switchRatio = pow(10, switchMarginDB / 20)
        self.switchSustainSeconds = switchSustainSeconds
        self.attackSeconds = attackSeconds
        self.releaseSeconds = releaseSeconds
        sustainWindow = WindowMinimum(channelCount: count, seconds: switchSustainSeconds, bins: Self.windowBins)
        qualifyWindow = WindowMinimum(channelCount: count, seconds: Self.holdQualifySeconds, bins: Self.windowBins)
        selected = self.pinned ?? 0
        levels = Array(repeating: 0, count: count)
        peakLevels = Array(repeating: 0, count: count)
        fast = Array(repeating: 0, count: count)
        lastFast = Array(repeating: 0, count: count)
        held = Array(repeating: 0, count: count)
        sustained = Array(repeating: 0, count: count)
        switches.reserveCapacity(Self.switchHistoryCapacity)
    }

    public mutating func observe(rms: UnsafeBufferPointer<Float>, frameCount: Int) -> Int {
        let count = min(rms.count, levels.count)
        guard count > 0, frameCount > 0, sampleRate > 0 else { return selected }
        let dt = Double(frameCount) / sampleRate
        elapsedSeconds += dt
        if !primed {
            primed = true
            for c in 0..<count {
                levels[c] = rms[c]; fast[c] = rms[c]; lastFast[c] = rms[c]; peakLevels[c] = rms[c]
            }
            sustainWindow.record(fast, dt: dt, count: count)
            qualifyWindow.record(levels, dt: dt, count: count)
            if pinned == nil { selected = loudest(rms, count: count) }
            return selected
        }
        let attack = Self.coefficient(dt, attackSeconds)
        let release = Self.coefficient(dt, releaseSeconds)
        for c in 0..<count {
            let x = rms[c]
            fast[c] += attack * (x - fast[c])
            levels[c] += (x > levels[c] ? attack : release) * (x - levels[c])
            peakLevels[c] = max(peakLevels[c], levels[c])
        }
        sustainWindow.record(fast, dt: dt, count: count)
        qualifyWindow.record(levels, dt: dt, count: count)
        let qualified = sustainWindow.isFull && qualifyWindow.isFull
        let holdDecay = Float(exp(-dt / Self.peakHoldDecaySeconds))
        for c in 0..<count {
            sustained[c] = min(sustainWindow.minimum(c), fast[c], lastFast[c])
            let lasting = min(sustained[c], qualifyWindow.minimum(c))
            held[c] = qualified ? max(held[c] * holdDecay, lasting) : held[c] * holdDecay
            lastFast[c] = fast[c]
        }
        guard pinned == nil else { return selected }
        updateCandidate(dt: dt, count: count)
        return selected
    }

    private mutating func updateCandidate(dt: Double, count: Int) {
        var best = -1
        for c in 0..<count where c != selected && (best < 0 || fast[c] > fast[best]) { best = c }
        let bar = max(held[selected], sustained[selected]) * switchRatio
        guard best >= 0, fast[best] > bar else {
            candidate = -1; candidateSeconds = 0; candidateBuffers = 0
            return
        }
        if best != candidate { candidate = best; candidateSeconds = 0; candidateBuffers = 0 }
        candidateSeconds += dt
        candidateBuffers += 1
        guard candidateSeconds >= switchSustainSeconds, candidateBuffers >= Self.minimumSustainBuffers else { return }
        if switches.count == Self.switchHistoryCapacity { switches.removeFirst() }
        switches.append(SwitchRecord(atSeconds: elapsedSeconds, from: selected, to: best, levels: levels))
        switchCount += 1
        selected = best
        candidate = -1; candidateSeconds = 0; candidateBuffers = 0
    }

    public var logSummary: String {
        var parts = ["channels=\(levels.count)", "selected=\(selected)", "switches=\(switchCount)",
                     "peak=\(Self.format(peakLevels))"]
        for record in switches {
            parts.append("switch=[t=\(String(format: "%.2f", record.atSeconds))s \(record.from)→\(record.to) levels=\(Self.format(record.levels))]")
        }
        return parts.joined(separator: " ")
    }

    private static func format(_ values: [Float]) -> String {
        "[" + values.map { String(format: "%.4f", $0) }.joined(separator: ",") + "]"
    }

    private func loudest(_ rms: UnsafeBufferPointer<Float>, count: Int) -> Int {
        var best = 0
        for c in 1..<max(1, count) where rms[c] > rms[best] { best = c }
        return best
    }

    private static func coefficient(_ dt: Double, _ tau: Double) -> Float {
        tau > 0 ? Float(1 - exp(-dt / tau)) : 1
    }
}

// The lowest value each channel held over a trailing window, kept in fixed bins so recording never allocates.
private struct WindowMinimum: Sendable {
    private let bins: Int
    private let binSeconds: Double
    private var values: [Float]
    private var index = 0
    private var elapsed = 0.0
    private var filled = 0

    init(channelCount: Int, seconds: Double, bins: Int) {
        self.bins = bins
        binSeconds = max(seconds / Double(bins), 0.0001)
        values = Array(repeating: .infinity, count: channelCount * bins)
    }

    var isFull: Bool { filled >= bins }

    func minimum(_ channel: Int) -> Float {
        var lowest = Float.infinity
        for b in 0..<bins { lowest = min(lowest, values[channel * bins + b]) }
        return lowest
    }

    mutating func record(_ level: [Float], dt: Double, count: Int) {
        var remaining = dt
        var advanced = 0
        while remaining > 0, advanced <= bins {
            write(level, count: count)
            let room = binSeconds - elapsed
            if remaining < room { elapsed += remaining; break }
            remaining -= room
            elapsed = 0
            index = (index + 1) % bins
            filled = min(bins, filled + 1)
            for c in 0..<count { values[c * bins + index] = .infinity }
            advanced += 1
        }
        write(level, count: count)
    }

    private mutating func write(_ level: [Float], count: Int) {
        for c in 0..<count {
            let i = c * bins + index
            values[i] = min(values[i], level[c])
        }
    }
}
