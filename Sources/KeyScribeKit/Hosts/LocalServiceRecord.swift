import Foundation

public enum LocalServiceRecord {
    public static let writtenWithin: TimeInterval = 2

    public static func trusts(processStarted: Date?, recordedAt: Date) -> Bool {
        guard let processStarted else { return false }
        return processStarted <= recordedAt.addingTimeInterval(writtenWithin)
    }

    public static func loopback(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), ["http", "https"].contains(url.scheme),
              let host = url.host(percentEncoded: false), ["127.0.0.1", "localhost", "::1"].contains(host)
        else { return nil }
        return url
    }
}
