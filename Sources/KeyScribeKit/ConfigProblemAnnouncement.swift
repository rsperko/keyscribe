public struct ConfigProblemAnnouncement: Sendable {
    private var lastSeen: Set<String>

    public init(baseline: [String] = []) {
        lastSeen = Set(baseline)
    }

    public mutating func next(current: [String]) -> [String] {
        defer { lastSeen = Set(current) }
        return current.filter { !lastSeen.contains($0) }
    }
}
