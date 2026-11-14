import Foundation
import KeyScribeKit

enum AgentGuideWriter {
    static func refresh(supportDir: URL = KeyScribePaths.supportDir) {
        let values = AgentGuide.Values(
            appName: Branding.appName,
            supportDir: supportDir.path,
            executable: Bundle.main.executablePath ?? CommandLine.arguments[0],
            version: DiagnosticsCollector.appVersion())
        guard let files = bundledFiles(values: values) else {
            Log.config.error("agent guide templates are missing from the app bundle")
            return
        }
        if !files.contains(where: { $0.path.hasPrefix(AgentGuide.referenceDirectory + "/") }) {
            Log.config.error("config schema is missing from the app bundle; the agent guide points at a reference it cannot write")
        }
        write(files, to: supportDir)
    }

    static func bundledFiles(values: AgentGuide.Values) -> [AgentGuide.File]? {
        let templates = bundledTemplates()
        guard !templates.isEmpty else { return nil }
        let schema = Bundle.main.url(forResource: "config_schema", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        return AgentGuide.files(templates: templates, schema: schema, values: values)
    }

    private static func bundledTemplates() -> [String: String] {
        for location in ConnectorResources.bundleLocations() {
            guard let folder = Bundle(url: location)?.url(forResource: "AgentGuide", withExtension: nil),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
            else { continue }
            var templates: [String: String] = [:]
            for name in names where name.hasSuffix(".md") {
                templates[name] = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            }
            return templates
        }
        return [:]
    }

    static func write(_ files: [AgentGuide.File], to supportDir: URL) {
        for file in files {
            let url = supportDir.appendingPathComponent(file.path)
            let exists = FileManager.default.fileExists(atPath: url.path)
            let existing = exists ? try? String(contentsOf: url, encoding: .utf8) : nil
            if existing == file.contents { continue }
            do {
                if exists, !(existing.map(AgentGuide.isManaged) ?? false) {
                    try FileManager.default.moveItem(at: url, to: url.appendingPathExtension(backupSuffix()))
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Log.config.error("agent guide \(file.path, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func backupSuffix() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "bak-" + formatter.string(from: Date())
    }
}
