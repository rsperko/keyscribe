import Foundation

public struct BBBuild: Equatable, Sendable {
    public var folder: String
    public var app: String?
    public var bundle: String?
    public var name: String

    public init(folder: String, app: String? = nil, bundle: String? = nil, name: String) {
        self.folder = folder
        self.app = app
        self.bundle = bundle
        self.name = name
    }

    public var launcher: String { (folder as NSString).appendingPathComponent(BBBuilds.launcherPath) }
}

public enum BBBuilds {
    public static let usualFolder = ".bb"
    public static let launcherPath = "bin/bb"
    public static let runtimeFile = "bb-app-runtime.json"
    public static let threadStorage = "thread-storage"
    public static let serverKey = "BB_SERVER_URL"
    public static let dataFolderKey = "BB_DATA_DIR"
    public static let fallbackName = "bb"

    public static func app(runtime: Data?, launcher: String?) -> String? {
        struct Runtime: Decodable { var entryPath: String? }
        if let entry = runtime.flatMap({ try? JSONDecoder().decode(Runtime.self, from: $0) })?.entryPath, let app = bundle(containing: entry) {
            return app
        }
        guard let launcher else { return nil }
        for line in launcher.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("runtime="), let value = shellWord(String(text.dropFirst("runtime=".count))) else { continue }
            return bundle(containing: value)
        }
        return nil
    }

    public static func environment(folder: String, home: String, runtime: Data?, alive: (Int32) -> Bool) -> [String: String] {
        var environment = ["HOME": home, "PATH": "/usr/bin:/bin", "BB_TELEMETRY": "false", dataFolderKey: folder]
        if let server = localServer(runtime: runtime, alive: alive) { environment[serverKey] = server }
        return environment
    }

    private static func localServer(runtime: Data?, alive: (Int32) -> Bool) -> String? {
        struct Runtime: Decodable {
            var pid: Int32?
            var serverUrl: String?
        }
        guard let record = runtime.flatMap({ try? JSONDecoder().decode(Runtime.self, from: $0) }),
              let pid = record.pid, pid > 0, alive(pid), let text = record.serverUrl,
              let url = URL(string: text), ["http", "https"].contains(url.scheme), let host = url.host(percentEncoded: false),
              ["127.0.0.1", "localhost", "::1"].contains(host)
        else { return nil }
        return text
    }

    public static func dataFolder(environment: [String: Any]?, home: String) -> String? {
        guard let value = environment?[dataFolderKey] as? String else { return nil }
        if value == "~" { return home }
        if value.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(value.dropFirst(2))) }
        return value.hasPrefix("/") ? value : nil
    }

    public static func name(info: [String: Any]?, app: String?) -> String {
        let file = app.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? ""
        return file.isEmpty ? name(info: info) : file
    }

    public static func name(info: [String: Any]?) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        return fallbackName
    }

    public static func preferred(_ builds: [BBBuild], open: (BBBuild) -> Bool, home: String) -> BBBuild? {
        let usual = (home as NSString).appendingPathComponent(usualFolder)
        let ordered = builds.filter { $0.folder == usual } + builds.filter { $0.folder != usual }
        return ordered.first(where: open) ?? ordered.first
    }

    private static func bundle(containing path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            parts.append(String(part))
            if part.hasSuffix(".app") { return "/" + parts.joined(separator: "/") }
        }
        return nil
    }

    private static func shellWord(_ text: String) -> String? {
        guard text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 else { return text.contains(" ") ? nil : text }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }
}
