import Foundation

public struct HistorySearchScope: Hashable, Sendable {
    public enum Period: Hashable, Sendable {
        case days(Int)
        case all
    }

    public enum Filter: Hashable, Sendable {
        case all
        case named(String)
    }

    public var period: Period
    public var model: Filter

    public init(period: Period, model: Filter) {
        self.period = period
        self.model = model
    }

    public static let defaultPeriod = Period.days(30)

    public static func defaults(in items: [HistorySnapshot.Item], now: Date) -> HistorySearchScope {
        let unfiltered = HistorySearchScope(period: defaultPeriod, model: .all)
        let recent = recordedModels(in: unfiltered.matching(items, now: now)).first
        return HistorySearchScope(period: defaultPeriod, model: recent.map(Filter.named) ?? .all)
    }

    public func matching(_ items: [HistorySnapshot.Item], now: Date) -> [HistorySnapshot.Item] {
        withinPeriod(items, now: now).filter { item in
            guard case .named(let name) = model else { return true }
            return item.entry.engine == name
        }
    }

    public func withoutRecordedModel(_ items: [HistorySnapshot.Item], now: Date) -> Int {
        guard case .named = model else { return 0 }
        return withinPeriod(items, now: now).filter { $0.entry.engine == nil }.count
    }

    public static func recordedModels(in items: [HistorySnapshot.Item]) -> [String] {
        var latest: [String: Date] = [:]
        for item in items {
            guard let engine = item.entry.engine else { continue }
            latest[engine] = max(latest[engine] ?? .distantPast, item.entry.timestamp)
        }
        return latest.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    private func withinPeriod(_ items: [HistorySnapshot.Item], now: Date) -> [HistorySnapshot.Item] {
        items.filter { item in
            if case .days(let days) = period,
               item.entry.timestamp < now.addingTimeInterval(-Double(days) * 86_400) { return false }
            return true
        }
    }
}
