public struct ConfigProblemAnnouncement: Sendable {
    private var lastSeen: Set<String>

    public init(baseline: [ConfigFileIssue] = []) {
        lastSeen = Set(baseline.map(\.oneLine))
    }

    public mutating func next(current: [ConfigFileIssue]) -> [ConfigFileIssue] {
        defer { lastSeen = Set(current.map(\.oneLine)) }
        return current.filter { !lastSeen.contains($0.oneLine) }
    }
}
