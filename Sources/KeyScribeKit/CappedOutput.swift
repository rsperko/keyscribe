import Foundation

public struct CappedOutput: Equatable, Sendable {
    public let limit: Int
    public private(set) var data = Data()
    public private(set) var truncated = false

    public init(limit: Int) {
        self.limit = limit
    }

    public mutating func append(_ bytes: Data) {
        let room = limit - data.count
        if bytes.count > room { truncated = true }
        if room > 0 { data.append(bytes.prefix(room)) }
    }

    public var text: String { String(decoding: data, as: UTF8.self) }
}

public struct ScriptOutput: Equatable, Sendable {
    public var output: CappedOutput
    public var errors: CappedOutput
    public var status: Int32?

    public init(output: CappedOutput, errors: CappedOutput, status: Int32? = nil) {
        self.output = output
        self.errors = errors
        self.status = status
    }
}
