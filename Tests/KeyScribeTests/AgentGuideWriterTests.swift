import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct AgentGuideWriterTests {
    private let values = AgentGuide.Values(appName: "KeyScribeDev", supportDir: "/tmp/x", executable: "/bin/ks", version: "1.0 (1)")

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyscribe-guide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let marker = "<!-- Managed by {{app_name}}. -->\n"

    private func files(agents: String = "agents") -> [AgentGuide.File] {
        AgentGuide.files(
            templates: ["README.md": Self.marker + "readme", "AGENTS.md": Self.marker + agents], schema: "schema", values: values)
    }

    private func managed(_ body: String) -> String { "<!-- Managed by KeyScribeDev. -->\n" + body }

    private func backups(of name: String, in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(name + ".") }
    }

    private func read(_ path: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func writesEveryManagedFile() throws {
        let dir = try tempDir()
        AgentGuideWriter.write(files(), to: dir)
        #expect(read("README.md", in: dir) == managed("readme"))
        #expect(read("AGENTS.md", in: dir) == managed("agents"))
        #expect(read("reference/config_schema.md", in: dir)?.hasSuffix("schema") == true)
    }

    @Test func leavesAnUnchangedFileUntouched() throws {
        let dir = try tempDir()
        AgentGuideWriter.write(files(), to: dir)
        let agents = dir.appendingPathComponent("AGENTS.md")
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: agents.path)
        AgentGuideWriter.write(files(), to: dir)
        let stamp = try FileManager.default.attributesOfItem(atPath: agents.path)[.modificationDate] as? Date
        #expect(stamp == past)
    }

    @Test func refreshesAManagedFileWithoutKeepingACopy() throws {
        let dir = try tempDir()
        AgentGuideWriter.write(files(), to: dir)
        try managed("my edit").write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        AgentGuideWriter.write(files(agents: "agents v2"), to: dir)
        #expect(read("AGENTS.md", in: dir) == managed("agents v2"))
        #expect(try backups(of: "AGENTS.md", in: dir).isEmpty)
    }

    @Test func movesAFileTheUserWroteAsideBeforeReplacingIt() throws {
        let dir = try tempDir()
        try "my own agent notes".write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        AgentGuideWriter.write(files(), to: dir)
        #expect(read("AGENTS.md", in: dir) == managed("agents"))
        let saved = try backups(of: "AGENTS.md", in: dir)
        #expect(saved.count == 1)
        #expect(saved.first.flatMap { read($0, in: dir) } == "my own agent notes")
    }

    @Test func keepsAFileItCannotReadAsTextBeforeReplacingIt() throws {
        let dir = try tempDir()
        let original = try #require("my notes in UTF-16".data(using: .utf16))
        try original.write(to: dir.appendingPathComponent("AGENTS.md"))
        AgentGuideWriter.write(files(), to: dir)
        #expect(read("AGENTS.md", in: dir) == managed("agents"))
        let saved = try backups(of: "AGENTS.md", in: dir)
        #expect(saved.count == 1)
        #expect(try saved.first.map { try Data(contentsOf: dir.appendingPathComponent($0)) } == original)
    }

    @Test func neverTouchesTheUsersOwnInstructionFiles() throws {
        let dir = try tempDir()
        try "mine".write(to: dir.appendingPathComponent("AGENTS.override.md"), atomically: true, encoding: .utf8)
        try "@AGENTS.override.md".write(to: dir.appendingPathComponent("CLAUDE.local.md"), atomically: true, encoding: .utf8)
        AgentGuideWriter.write(files(), to: dir)
        #expect(read("AGENTS.override.md", in: dir) == "mine")
        #expect(read("CLAUDE.local.md", in: dir) == "@AGENTS.override.md")
    }

    @Test func theShippedGuideNeverIncludesTheUsersOwnInstructionFiles() throws {
        let paths = try #require(AgentGuideWriter.bundledFiles(values: values)).map(\.path)
        #expect(paths.contains("AGENTS.md"))
        #expect(paths.contains("CLAUDE.md"))
        #expect(!paths.contains("AGENTS.override.md"))
        #expect(!paths.contains("CLAUDE.local.md"))
    }

    @Test func everyShippedFileCarriesTheManagedMarker() throws {
        for file in try #require(AgentGuideWriter.bundledFiles(values: values)) {
            #expect(AgentGuide.isManaged(file.contents), "\(file.path) lacks the managed marker")
        }
    }

    @Test func theShippedGuideNamesEveryTopLevelConfigFile() throws {
        let agents = try #require(AgentGuideWriter.bundledFiles(values: values)?.first { $0.path == "AGENTS.md" }?.contents)
        for name in [SettingsStore.fileName, ConnectionStore.fileName, DictionaryStore.fileName,
                     ReplacementsStore.fileName, VoiceCommandStore.fileName] {
            #expect(agents.contains("`\(name)`"), "AGENTS.md does not describe \(name)")
        }
    }

    @Test func theShippedGuideFencesOffEveryPrivateFolder() throws {
        let agents = try #require(AgentGuideWriter.bundledFiles(values: values)?.first { $0.path == "AGENTS.md" }?.contents)
        for folder in ConfigWatchFilter.ignoredSubdirectories where folder != AgentGuide.referenceDirectory {
            #expect(agents.contains("`\(folder)/`"), "AGENTS.md does not fence off \(folder)/")
        }
    }

    @Test func theShippedGuideRendersCompletely() throws {
        let files = try #require(AgentGuideWriter.bundledFiles(values: values))
        for file in files where ["README.md", "AGENTS.md"].contains(file.path) {
            #expect(!file.contents.contains("{{"), "\(file.path) has an unfilled placeholder")
            #expect(file.contents.contains("KeyScribeDev"), "\(file.path) never names the app")
        }
    }

    @Test func theShippedReadmeNamesEveryManagedFile() throws {
        let files = try #require(AgentGuideWriter.bundledFiles(values: values))
        let readme = try #require(files.first { $0.path == "README.md" }?.contents)
        let tops = Set(files.map { $0.path.split(separator: "/").count > 1 ? String($0.path.split(separator: "/")[0]) + "/" : $0.path })
        for top in tops {
            #expect(readme.contains("`\(top)`"), "README.md does not mention \(top)")
        }
    }

    @Test func theShippedGuideTellsAgentsToRunTheConfigCheck() throws {
        let files = try #require(AgentGuideWriter.bundledFiles(values: values))
        let agents = try #require(files.first { $0.path == "AGENTS.md" }?.contents)
        #expect(agents.contains("\"/bin/ks\" \(ConfigCheck.flag) --config-dir \"/tmp/x\""))
        #expect(agents.contains("AGENTS.override.md"))
    }
}
