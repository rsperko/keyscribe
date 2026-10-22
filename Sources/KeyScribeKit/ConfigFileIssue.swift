import Foundation

public struct ConfigFileIssue: Equatable, Sendable, Identifiable {
    public enum Recovery: Equatable, Sendable { case previousVersion, ignored, defaults }
    public enum Kind: Equatable, Sendable { case unreadable(Recovery), unusedKeys }
    public enum Cause: Equatable, Sendable {
        case syntax(line: Int, column: Int), unreadableFile, newerSchema, missingSchema, invalidValue, unusedKeys
    }

    public let fileName: String
    public let relativePath: String
    public let kind: Kind
    public let detail: String
    public let cause: Cause

    public var id: String { "\(relativePath)|\(isError)" }
    public var isError: Bool { if case .unreadable = kind { true } else { false } }

    public static func unreadable(
        _ fileName: String, relativePath: String? = nil, error: ConfigError, recovery: Recovery
    ) -> ConfigFileIssue {
        let (detail, position) = splitLocation(error.summary)
        let cause: Cause = switch error {
        case .newerSchemaVersion: .newerSchema
        case .missingSchemaVersion: .missingSchema
        case .unreadableFile: .unreadableFile
        case .invalid: position.map { .syntax(line: $0.line, column: $0.column) } ?? .invalidValue
        }
        return ConfigFileIssue(
            fileName: fileName, relativePath: relativePath ?? fileName,
            kind: .unreadable(recovery), detail: detail, cause: cause)
    }

    public static func unusedKeys(
        _ fileName: String, relativePath: String? = nil, _ keys: [UnknownConfigKey]
    ) -> ConfigFileIssue {
        ConfigFileIssue(
            fileName: fileName, relativePath: relativePath ?? fileName, kind: .unusedKeys,
            detail: keys.map(\.description).joined(separator: ", "), cause: .unusedKeys)
    }

    public var title: String {
        isError ? "Couldn’t read \(relativePath)" : "\(relativePath) has a key nothing reads"
    }

    public var technicalDetails: String {
        [location, detail].compactMap { $0 }.joined(separator: "\n")
    }

    public var location: String? {
        guard case .syntax(let line, let column) = cause else { return nil }
        return "Line \(line), column \(column)"
    }

    public var explanation: String {
        switch cause {
        case .syntax(let line, let column):
            "There’s a formatting mistake near line \(line), column \(column) — often a missing quote, bracket, or comma."
        case .newerSchema: "It was saved by a newer version of this app."
        case .missingSchema: "It’s missing its schema_version line."
        case .unreadableFile: "It couldn’t be opened as text. Check that you can read it and that it’s saved as UTF-8."
        case .invalidValue: "Something in it isn’t valid for this app."
        case .unusedKeys: "It has a key this app doesn’t read, usually a typo, so that line has no effect."
        }
    }

    // While settings.toml can't be replaced, in-app changes to it apply but are not saved, and fixing the file
    // reloads it over them.
    public var recovery: String {
        let state = switch kind {
        case .unreadable(.previousVersion): "The previous version is still in use."
        case .unreadable(.defaults): "Default settings are in use until it’s fixed."
        case .unreadable(.ignored): "It’s ignored until it’s fixed."
        case .unusedKeys: "It has no effect."
        }
        guard isError, relativePath == SettingsStore.fileName else { return state }
        return state + " App-wide settings you change meanwhile are temporary: fixing the file reloads it and replaces them. Modes and vocabulary still save normally."
    }

    public var oneLine: String {
        switch kind {
        case .unreadable(let recovery):
            let message = [detail, location].compactMap { $0 }.joined(separator: ", ")
            let state = switch recovery {
            case .previousVersion: "previous version still in use"
            case .defaults: "using defaults until fixed"
            case .ignored: "ignored until fixed"
            }
            return "Couldn’t read \(fileName) — \(message) — \(state)"
        case .unusedKeys:
            return "\(fileName) — \(detail) has no effect"
        }
    }

    public static func menuSummary(_ errors: [ConfigFileIssue]) -> String? {
        switch errors.count {
        case 0: nil
        case 1: errors[0].relativePath == SettingsStore.fileName ? "Settings file needs attention…" : "A config file needs attention…"
        default: "\(errors.count) config files need attention…"
        }
    }

    private static func splitLocation(_ message: String) -> (String, (line: Int, column: Int)?) {
        guard let match = message.firstMatch(of: /\s*\(at line (\d+), column (\d+)\)\s*$/),
              let line = Int(match.1), let column = Int(match.2) else { return (message, nil) }
        return (String(message[..<match.range.lowerBound]), (line, column))
    }
}
