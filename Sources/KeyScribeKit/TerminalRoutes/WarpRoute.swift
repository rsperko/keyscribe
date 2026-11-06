import Foundation

struct WarpRoute: TerminalRoute {
    static let focusKey = "WARP_FOCUS_URL"
    let name = "Warp"
    let app = "dev.warp.Warp-Stable"
    let environmentKeys = [focusKey]
    let frontScript: String? = nil

    func open(_ process: TerminalProcess, inner: ArraySlice<TerminalProcess>, facts: TerminalFacts) -> Opening? {
        guard process.app == app else { return nil }
        let activate = OpenAction.activate(app: app, pid: process.pid)
        guard let url = inner.reversed().lazy.compactMap({ $0.environment[Self.focusKey] }).first(where: { $0.hasPrefix("warp://") })
        else { return Opening([activate]) }
        return Opening([.select(.url(url)), activate])
    }
}
