import Foundation

// Shared prompt fragments are markdown files with a small YAML frontmatter header
// (config_schema.md `fragments/<id>.md`). A mode's `ai_rewrite.fragments` lists ids; their bodies
// are appended to the mode's prompt in order.
public enum FragmentStore {
    /// The fragment text: everything after the leading `---`…`---` YAML header (or the whole file,
    /// trimmed, when there is no header).
    public static func body(ofFile content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let close = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lines[(close + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The display name from the YAML `name:` field, or `nil` when there is no header, no `name:`
    /// line, or an empty value.
    public static func name(ofFile content: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let close = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return nil }
        for line in lines[1..<close] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("name:") else { continue }
            let value = trimmed.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Replace the body (everything after the YAML header) with `newBody`, keeping the header so the
    /// `name:` survives. With no header the trimmed body is returned on its own.
    public static func replacingBody(inFile content: String, with newBody: String) -> String {
        let body = newBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            return body
        }
        let header = lines[0...close].joined(separator: "\n")
        return body.isEmpty ? header + "\n" : header + "\n" + body + "\n"
    }

    /// The display name for `dir/<id>.md`, or `nil` when the file is missing or has no `name:`.
    public static func name(id: String, in dir: URL) -> String? {
        let url = dir.appendingPathComponent("\(id).md")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return name(ofFile: content)
    }

    /// Bodies for the given fragment ids, read from `dir/<id>.md`, in order. Missing/unreadable
    /// fragments are skipped.
    public static func load(ids: [String], from dir: URL) -> [String] {
        ids.compactMap { id in
            let url = dir.appendingPathComponent("\(id).md")
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let text = body(ofFile: content)
            return text.isEmpty ? nil : text
        }
    }

    /// Filename-safe id derived from a display name: lowercased, runs of non-alphanumerics
    /// collapsed to single hyphens. Empty when the name has no usable characters.
    public static func slug(for name: String) -> String {
        name.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init).joined(separator: "-")
    }

    /// Existing fragment ids (the `.md` filename stems) in `dir`, sorted.
    public static func ids(in dir: URL) -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public enum FragmentError: Error { case emptyName }

    /// Resolve `name` to a fragment id, creating `dir/<id>.md` with a header and empty body when no
    /// fragment with that id exists (the editor shows a ghost-text prompt, not seeded content). An
    /// existing file is left untouched so referencing it by name never clobbers its content. Returns
    /// the id and whether a file was actually written (`created == false` means it already existed, so
    /// no on-disk change happened). Throws on a name with no usable characters.
    @discardableResult
    public static func createIfNeeded(name: String, in dir: URL) throws -> (id: String, created: Bool) {
        let id = slug(for: name)
        guard !id.isEmpty else { throw FragmentError.emptyName }
        let url = dir.appendingPathComponent("\(id).md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return (id, false) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let starter = """
            ---
            schema_version: 1
            name: \(title.isEmpty ? id : title)
            ---

            """
        try starter.write(to: url, atomically: true, encoding: .utf8)
        return (id, true)
    }
}
