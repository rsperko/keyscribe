import Foundation

// Pure retention decision (design.md §4.7): given the day-file names and today's date, return the
// files older than `retentionDays` so the store can delete them. Day files are named
// `yyyy-MM-dd.jsonl`. `today` is passed in (not read from the clock) so this stays deterministic.
public enum HistoryRetention {
    public static func expired(dayFiles: [String], today: String, retentionDays: Int) -> [String] {
        guard let todayDate = date(from: today) else { return [] }
        return dayFiles.filter { file in
            guard let fileDate = date(from: stem(of: file)) else { return false }
            let ageDays = Int((todayDate.timeIntervalSince(fileDate) / 86_400).rounded())
            return ageDays > retentionDays
        }
    }

    private static func stem(of file: String) -> String {
        file.hasSuffix(".jsonl") ? String(file.dropLast(6)) : file
    }

    private static func date(from ymd: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd)
    }
}
