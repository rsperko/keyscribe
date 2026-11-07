import Foundation

public enum ShellWord {
    public static func isSafe(_ text: some StringProtocol, allowingHome: Bool = false) -> Bool {
        !text.isEmpty && text.first != "=" && text.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "_-./:,@%+=".contains($0) || (allowingHome && $0 == "~"))
        }
    }

    public static func quoted(_ text: some StringProtocol, allowingHome: Bool = false) -> String {
        if isSafe(text, allowingHome: allowingHome) { return String(text) }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func path(_ path: String, home: String) -> String {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return quoted(path) }
        return "~/" + quoted(path.dropFirst(prefix.count))
    }
}
