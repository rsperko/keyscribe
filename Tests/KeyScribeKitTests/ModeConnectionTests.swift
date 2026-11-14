import Foundation
import Testing
@testable import KeyScribeKit

struct ModeConnectionTests {
    private let connections = ConnectionSet(connections: [
        Connection(id: "fast", name: "Fast", provider: .gemini, model: "m", keyRef: "keyscribe.llm.fast"),
    ])

    private func mode(connection: String?) -> Mode {
        var mode = Mode(id: "m", name: "M")
        mode.aiRewrite = connection.map { Mode.AIRewrite(connection: $0, prompt: "p") }
        return mode
    }

    @Test func aModeWithoutARewriteNeedsNoConnection() {
        #expect(!mode(connection: nil).lacksConnection(in: connections))
    }

    @Test func aRewriteNeedsANamedConnectionThatExists() {
        #expect(!mode(connection: "fast").lacksConnection(in: connections))
        #expect(mode(connection: "").lacksConnection(in: connections))
        #expect(mode(connection: "gone").lacksConnection(in: connections))
    }
}
