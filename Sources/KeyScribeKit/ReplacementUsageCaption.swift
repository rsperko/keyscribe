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
        let uses = "Used in \(dictations(entry.count))"
        guard let lastUsed = entry.lastUsed, let last = relative(lastUsed, today: today, locale: locale) else {
            return uses
        }
        return "\(uses) · last used \(last)"
    }

    // Problems the rule caused as it is now. Recorded when the dictations happened, so it describes what took
    // place then, not what today's rules would do to them.
    public static func health(for entry: ReplacementUsage.Entry?, rule: ReplacementsSet.Rule) -> [String] {
        let current = ReplacementUsage.fingerprint(
            heard: rule.heard, replace: rule.replace, regex: rule.regex, wholeDictation: rule.wholeDictation)
        guard let health = entry?.health, health.fingerprint == current else { return [] }
        var lines: [String] = []
        if health.insideWord > 0 {
            lines.append("changed text inside other words in \(dictations(health.insideWord))")
        }
        if health.returnOmitted > 0 {
            lines.append("did not press Return in \(dictations(health.returnOmitted)), because it matched mid-sentence")
        }
        guard !lines.isEmpty else { return [] }
        if health.editedOn != nil {
            return ["Since you edited it: " + lines.joined(separator: "; ")]
        }
        return lines.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    private static func dictations(_ count: Int) -> String {
        count == 1 ? "1 dictation" : "\(count) dictations"
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
