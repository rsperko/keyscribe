import Foundation
import KeyScribeKit

extension OpencodeInstall {
    static func search(in tools: ToolEnvironment = .shared, chosen: String? = nil) -> ToolSearch.Result {
        tools.search(program: command, agent: OpencodeSession.agent, setup: nil, chosen: chosen, extra: [], accepting: { _ in true })
    }

    static func find(in tools: ToolEnvironment = .shared) -> String? {
        search(in: tools).tool?.path
    }
}
