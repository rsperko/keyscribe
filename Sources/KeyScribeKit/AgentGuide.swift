import Foundation

public enum AgentGuide {
    public struct Values: Sendable {
        public let appName: String
        public let supportDir: String
        public let executable: String
        public let version: String

        public init(appName: String, supportDir: String, executable: String, version: String) {
            self.appName = appName
            self.supportDir = supportDir
            self.executable = executable
            self.version = version
        }
    }

    public struct File: Equatable, Sendable {
        public let path: String
        public let contents: String
    }

    public static let referenceDirectory = "reference"
    static let managedMarker = "<!-- Managed by "

    public static func isManaged(_ text: String) -> Bool {
        text.hasPrefix(managedMarker)
    }

    public static func files(templates: [String: String], schema: String?, values: Values) -> [File] {
        var files = templates.sorted { $0.key < $1.key }.map { File(path: $0.key, contents: render($0.value, values)) }
        if let schema {
            files.append(File(path: "\(referenceDirectory)/config_schema.md", contents: render(schemaHeader, values) + schema))
        }
        return files
    }

    private static let schemaHeader = """
        \(managedMarker){{app_name}} {{version}}. Rewritten on every launch; edits here are lost. -->
        <!-- This copy describes the default install. Here, the configuration folder is "{{support_dir}}" and \
        the app's executable is "{{executable}}". Links to other documents point into the project's repository \
        and do not resolve in this folder. -->

        """

    static func render(_ template: String, _ values: Values) -> String {
        template
            .replacingOccurrences(of: "{{app_name}}", with: values.appName)
            .replacingOccurrences(of: "{{support_dir}}", with: values.supportDir)
            .replacingOccurrences(of: "{{executable}}", with: values.executable)
            .replacingOccurrences(of: "{{version}}", with: values.version)
    }
}
