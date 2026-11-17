import Foundation

public struct ShellEnvironment: Equatable, Sendable {
    public static let pathKey = "PATH"
    static let markerPrefix = "__KEYSCRIBE_ENV_"

    public var values: [String: String]

    public init(values: [String: String]) {
        self.values = values
    }

    public var path: [String] {
        var seen: Set<String> = []
        return (values[Self.pathKey] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    public func folder(_ key: String, home: String) -> String? {
        guard let raw = values[key], !raw.isEmpty else { return nil }
        return FolderPath.resolve(raw, home: home, relativeTo: home)
    }

    public static func begin(_ nonce: String) -> String { markerPrefix + "BEGIN_" + nonce + "__" }
    public static func end(_ nonce: String) -> String { markerPrefix + "END_" + nonce + "__" }

    public static func script(nonce: String) -> String {
        "printf '%s%s' '\(markerPrefix)' 'BEGIN_\(nonce)__'; /usr/bin/env -0; printf '%s%s' '\(markerPrefix)' 'END_\(nonce)__'"
    }

    public static func flags(shell: String) -> [String] {
        ["sh", "dash"].contains((shell as NSString).lastPathComponent) ? ["-lc"] : ["-ilc", "-lc"]
    }

    public static func shell(environment: [String: String], account: String?) -> String {
        for candidate in [environment["SHELL"], account] {
            if let candidate, candidate.hasPrefix("/") { return candidate }
        }
        return "/bin/zsh"
    }

    public static func parse(_ output: Data, nonce: String, keys: Set<String>) -> ShellEnvironment? {
        let keys = keys.union([pathKey])
        guard let start = output.range(of: Data(begin(nonce).utf8)),
              let stop = output.range(of: Data(end(nonce).utf8), in: start.upperBound..<output.endIndex)
        else { return nil }
        var values: [String: String] = [:]
        for entry in output[start.upperBound..<stop.lowerBound].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "=") else { continue }
            let key = String(text[..<equals])
            if keys.contains(key) { values[key] = String(text[text.index(after: equals)...]) }
        }
        return ShellEnvironment(values: values)
    }
}

public enum ShellProbeState: Equatable, Sendable {
    case notRun
    case failed(String)
    case read(ShellEnvironment, at: Date, failure: String?)

    public var environment: ShellEnvironment? {
        if case .read(let environment, _, _) = self { return environment }
        return nil
    }
}
