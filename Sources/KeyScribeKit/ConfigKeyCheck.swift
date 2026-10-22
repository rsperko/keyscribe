import Foundation
import TOMLKit

public struct UnknownConfigKey: Equatable, Sendable {
    public let path: String
    public let suggestion: String?

    public var description: String {
        guard let suggestion else { return "“\(path)”" }
        return "“\(path)” (did you mean “\(suggestion)”?)"
    }
}

// A key the decoder never read is a key whose edit silently does nothing — most often a typo. Leans on
// TOMLKit's strict mode, which tracks reads per keyed container, so a type must read each table through
// ONE container or every key the other container skipped is reported.
enum ConfigKeyCheck {
    static func unknownKeys<T: Codable>(
        _ type: T.Type, in toml: String, supportedVersion: Int, migrations: [MigrationStep] = [],
        retired: Set<String> = [], examples: [T] = []
    ) -> [UnknownConfigKey] {
        guard let table = try? ConfigDecode.table(
            toml, supportedVersion: supportedVersion, migrations: migrations, { $0 }) else { return [] }
        let decoded = (try? TOMLDecoder().decode(T.self, from: table)).map { [$0] } ?? []
        let unread = unreadPaths(T.self, in: table)
        guard !unread.isEmpty else { return [] }
        let written = (decoded + examples).compactMap { try? TOMLTable(string: ConfigEncode.toml($0)) }
        return unread
            .filter { path in
                let name = dottedPath(path, indexed: false)
                return name != "schema_version" && !retired.contains(name)
            }
            .map { path in
                UnknownConfigKey(
                    path: dottedPath(path, indexed: true),
                    suggestion: suggestion(for: path, among: written))
            }
            .sorted { $0.path < $1.path }
    }

    // TOMLKit reports unread keys keyed by leaf name, so a second `regx` in another rule overwrites the first.
    // Each pass strips the keys it found and decodes again until a pass finds nothing new.
    private static func unreadPaths<T: Decodable>(_ type: T.Type, in table: TOMLTable) -> [[CodingKey]] {
        var found: [[CodingKey]] = []
        while true {
            let pass: [[CodingKey]]
            do {
                _ = try TOMLDecoder(strictDecoding: true).decode(T.self, from: table)
                return found
            } catch let error as UnexpectedKeysError {
                pass = Array(error.keys.values)
            } catch {
                return found
            }
            let removed = pass.filter { remove($0, from: table) }
            guard !removed.isEmpty else { return found + pass }
            found += removed
        }
    }

    private static func remove(_ path: [CodingKey], from table: TOMLTable) -> Bool {
        guard let leaf = path.last?.stringValue else { return false }
        var node: TOMLValueConvertible = table
        for component in path.dropLast() {
            if let index = component.intValue {
                guard let array = node.array, array.indices.contains(index) else { return false }
                node = array[index]
            } else {
                guard let child = node.table?[component.stringValue] else { return false }
                node = child
            }
        }
        return node.table?.remove(at: leaf) != nil
    }

    private static func dottedPath(_ path: [CodingKey], indexed: Bool) -> String {
        path.reduce(into: "") { result, key in
            if let index = key.intValue {
                if indexed { result += "[\(index)]" }
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
    }

    private static func suggestion(for path: [CodingKey], among written: [TOMLTable]) -> String? {
        guard let key = path.last?.stringValue else { return nil }
        let siblings = Set(written.flatMap { siblingKeys(at: path.dropLast(), in: $0) })
        let typed = key.lowercased()
        var best: (key: String, distance: Int)?
        for sibling in siblings.sorted() {
            let distance = FuzzyCorrector.levenshtein(typed, sibling.lowercased())
            guard distance > 0, distance <= 2, distance < key.count else { continue }
            if best == nil || distance < best!.distance { best = (sibling, distance) }
        }
        return best?.key
    }

    private static func siblingKeys(at path: ArraySlice<CodingKey>, in written: TOMLTable) -> [String] {
        var nodes: [TOMLValueConvertible] = [written]
        for component in path {
            nodes = nodes.flatMap { node -> [TOMLValueConvertible] in
                if component.intValue != nil { return node.array.map { Array($0) } ?? [] }
                return node.table?[component.stringValue].map { [$0] } ?? []
            }
        }
        return nodes.flatMap { $0.table?.keys ?? [] }
    }
}
