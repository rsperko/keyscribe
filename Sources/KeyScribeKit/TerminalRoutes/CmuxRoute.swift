import Foundation

struct CmuxRoute: TerminalRoute {
    static let app = "com.cmuxterm.app"
    let environmentKeys: [String] = []

    func owns(_ process: TerminalProcess) -> Bool { process.app == Self.app }

    func actions(terminal: TerminalProcess, inner: ArraySlice<TerminalProcess>) -> [OpenAction] {
        [.select(.connector), .activate(app: Self.app, pid: terminal.pid)]
    }
}
