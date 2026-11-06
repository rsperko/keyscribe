import Foundation

struct WarpRoute: TerminalRoute {
    static let app = "dev.warp.Warp-Stable"
    static let focusKey = "WARP_FOCUS_URL"
    let environmentKeys = [focusKey]

    func owns(_ process: TerminalProcess) -> Bool { process.app == Self.app }

    func actions(terminal: TerminalProcess, inner: ArraySlice<TerminalProcess>) -> [OpenAction] {
        let activate = OpenAction.activate(app: Self.app, pid: terminal.pid)
        guard let url = inner.reversed().lazy.compactMap({ $0.environment[Self.focusKey] }).first(where: { $0.hasPrefix("warp://") })
        else { return [activate] }
        return [.select(.url(url)), activate]
    }
}
