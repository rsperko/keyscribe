import Foundation

public struct OpencodeService: Equatable, Sendable {
    public static let user = "opencode"

    public var url: URL
    public var password: String?
    public var pid: Int
    public var version: String?

    public init(url: URL, password: String?, pid: Int, version: String?) {
        self.url = url
        self.password = password
        self.pid = pid
        self.version = version
    }

    public static func parse(_ data: Data) -> OpencodeService? {
        guard let object = OpencodeJSON.object(data), let address = object["url"] as? String, let url = URL(string: address),
              url.scheme == "http", let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host),
              let pid = OpencodeJSON.int(object["pid"])
        else { return nil }
        return OpencodeService(url: url, password: OpencodeJSON.text(object["password"]), pid: pid, version: OpencodeJSON.text(object["version"]))
    }

    public var authorization: String? {
        password.map { "Basic " + Data("\(Self.user):\($0)".utf8).base64EncodedString() }
    }

    public static func registration(home: String, environment: [String: String]) -> URL {
        let state = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (home as NSString).appendingPathComponent(".local/state")
        return URL(fileURLWithPath: state).appendingPathComponent("opencode/service.json")
    }
}

enum OpencodeJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}
