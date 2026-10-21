import Foundation

public enum ReplacementUsageCaption {
    public static func text(
        for entry: ReplacementUsage.Entry?, trackingSince: String?, today: String, locale: Locale = .current
    ) -> String? {
        guard let entry else { return nil }
        guard entry.count > 0 else {
            if let since = entry.since {
                if since == today { return "Added today" }
                if let added = describe(since, today: today, locale: locale) { return "Not used since added \(added)" }
            }
            guard let trackingSince, trackingSince != today,
                  let began = describe(trackingSince, today: today, locale: locale)
            else { return "No uses recorded yet" }
            return "No uses recorded since \(began)"
        }
        let uses = entry.count == 1 ? "Used once" : "Used \(entry.count) times"
        guard let lastUsed = entry.lastUsed, let last = relative(lastUsed, today: today, locale: locale) else {
            return uses
        }
        return "\(uses) · last used \(last)"
    }

    private static func relative(_ day: String, today: String, locale: Locale) -> String? {
        if day == today { return "today" }
        if let date = parse(day), let now = parse(today),
           calendar.date(byAdding: .day, value: 1, to: date) == now {
            return "yesterday"
        }
        return describe(day, today: today, locale: locale)
    }

    private static func describe(_ day: String, today: String, locale: Locale) -> String? {
        guard let date = parse(day), let now = parse(today) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }

    private static let calendar = Calendar(identifier: .gregorian)

    private static func parse(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }
}
