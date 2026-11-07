import Foundation

public enum FolderPath {
    public static func resolve(_ path: String, home: String, relativeTo base: String) -> String {
        let full = path == "~" ? home
            : path.hasPrefix("~/") ? home + path.dropFirst()
            : path.hasPrefix("/") ? path
            : base + "/" + path
        var parts: [Substring] = []
        for part in full.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
