import Foundation
import Testing
@testable import KeyScribe
@testable import KeyScribeKit

private struct FakeClient: LLMClient {
    let result: Result<String, Error>
    func complete(system: String, user: String, connection: Connection) async throws -> String {
        try result.get()
    }
}

@MainActor
struct ConnectionTesterTests {
    private let connection = Connection(
        id: "c", name: "C", provider: .openai, model: "m", keyRef: "k")

    @Test func passesWhenClientReplies() async {
        let tester = ConnectionTester(client: FakeClient(result: .success("OK")))
        #expect(await tester.test(connection) == .passed)
    }

    @Test func failureCarriesTheProviderMessage() async {
        let tester = ConnectionTester(client: FakeClient(result: .failure(LLMClientError.http(401, "nope"))))
        #expect(await tester.test(connection) == .failed("The model service returned an error (401)."))
    }

    @Test func emptyReplyIsFailure() async {
        let tester = ConnectionTester(client: FakeClient(result: .success("   \n")))
        guard case .failed = await tester.test(connection) else {
            Issue.record("expected an empty reply to be a failure")
            return
        }
    }
}

@MainActor
struct AIServiceTestStateTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyscribe-ai-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func recordsPassThenClearsItOnEdit() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AIServiceSettingsModel(
            supportDir: dir, tester: ConnectionTester(client: FakeClient(result: .success("OK"))))
        model.create()
        let connection = model.selected!

        model.test(connection)
        await model.testTask?.value
        #expect(model.testState(for: connection.id) == .passed)

        model.update(connection, apiKey: nil)
        #expect(model.testState(for: connection.id) == nil)
    }
}
