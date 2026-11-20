import Foundation
import Testing
@testable import KeyScribeApp

struct CommandWorkingFolderTests {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path

    private static func folder(_ output: String) -> String {
        URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
    }

    @Test func agentCommandsRunInsideTheHomeFolderButNeverInIt() async throws {
        let ran = ToolCLI.execute(["/bin/pwd"], timeout: 5).text
        let grouped = ToolCLI.executeGrouped(["/bin/pwd"], timeout: 5, environment: [:], includeErrors: false, limit: 4096).text
        let hosted = String(decoding: try await HostCLI.run(["/bin/pwd"], subcommand: "pwd").stdout, as: UTF8.self)
        for output in [ran, grouped, hosted] {
            let path = Self.folder(output)
            #expect(path == URL(fileURLWithPath: ToolCLI.workingFolder).resolvingSymlinksInPath().path)
            #expect(path != Self.home)
            #expect(path.hasPrefix(Self.home + "/"))
        }
    }
}
