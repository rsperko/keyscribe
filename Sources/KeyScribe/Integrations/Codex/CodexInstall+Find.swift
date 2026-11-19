import Foundation
import KeyScribeKit

extension CodexInstall {
    static func accepts(_ path: String, resolve: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) -> Bool {
        isCommandLine(resolved: path) && isCommandLine(resolved: resolve(path))
    }

    static func search(in tools: ToolEnvironment = .shared, home: String? = nil, chosen: String? = nil) -> ToolSearch.Result {
        tools.search(program: command, agent: CodexThread.agent, setup: home, chosen: chosen, extra: [], accepting: { accepts($0) })
    }

    static func find(in tools: ToolEnvironment = .shared) -> String? {
        search(in: tools).tool?.path
    }
}
