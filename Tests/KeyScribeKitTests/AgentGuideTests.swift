import Foundation
import Testing
@testable import KeyScribeKit

struct AgentGuideTests {
    private let values = AgentGuide.Values(
        appName: "KeyScribeDev", supportDir: "/Users/x/Library/Application Support/KeyScribeDev",
        executable: "/Applications/KeyScribeDev.app/Contents/MacOS/KeyScribe", version: "1.2.3 (45)")

    @Test func fillsEveryPlaceholder() {
        let template = "{{app_name}} keeps config in {{support_dir}}; check with \"{{executable}}\" ({{version}})."
        #expect(AgentGuide.render(template, values) ==
            "KeyScribeDev keeps config in /Users/x/Library/Application Support/KeyScribeDev; "
            + "check with \"/Applications/KeyScribeDev.app/Contents/MacOS/KeyScribe\" (1.2.3 (45)).")
    }

    @Test func rendersEachTemplateAtItsOwnPathAndAddsTheSchema() {
        let files = AgentGuide.files(
            templates: ["README.md": "readme {{app_name}}", "AGENTS.md": "agents {{app_name}}"], schema: "schema {{app_name}}",
            values: values)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.contents) })
        #expect(byPath == [
            "README.md": "readme KeyScribeDev", "AGENTS.md": "agents KeyScribeDev",
            "reference/config_schema.md": byPath["reference/config_schema.md"]!,
        ])
        #expect(byPath["reference/config_schema.md"]!.hasSuffix("\nschema {{app_name}}"))
    }

    @Test func marksTheSchemaCopyAsManagedAndNamesThisInstallsPaths() throws {
        let files = AgentGuide.files(templates: [:], schema: "schema", values: values)
        let schema = try #require(files.first { $0.path == "reference/config_schema.md" }?.contents)
        #expect(AgentGuide.isManaged(schema))
        #expect(schema.contains(values.supportDir))
        #expect(schema.contains(values.executable))
    }

    @Test func recognizesAManagedFileOnlyByItsLeadingMarker() {
        #expect(AgentGuide.isManaged("<!-- Managed by KeyScribe 1.0. Rewritten on every launch. -->\n# Guide"))
        #expect(!AgentGuide.isManaged("# My own notes\n<!-- Managed by KeyScribe -->"))
        #expect(!AgentGuide.isManaged(""))
    }

    @Test func leavesTheSchemaOutWhenTheBuildDoesNotCarryIt() {
        let paths = AgentGuide.files(templates: ["AGENTS.md": ""], schema: nil, values: values).map(\.path)
        #expect(!paths.contains("reference/config_schema.md"))
        #expect(paths.contains("AGENTS.md"))
    }
}
