import Foundation

enum KittyRoute {
    static let windowKey = "KITTY_WINDOW_ID"
    static let socketKey = "KITTY_LISTEN_ON"
    static let app = "net.kovidgoyal.kitty"
    static let name = "kitty"

    static let route = KeyedSurfaceRoute(
        name: name, apps: [app], key: windowKey, socket: socketKey,
        focus: .command { terminal, window, socket in
            guard let socket, isWindowID(window) else { return nil }
            return PaneCommand(remote(terminal, socket: socket) + ["focus-window", "--match", "id:\(window)"])
        },
        front: { terminal, socket, facts in
            guard let socket else { return .unknown(.unreported(name)) }
            return front(terminal, socket: socket, facts: facts)
        })

    static func remote(_ terminal: TerminalProcess, socket: String) -> [String] {
        let kitten = ((terminal.executable as NSString).deletingLastPathComponent as NSString).appendingPathComponent("kitten")
        return [kitten, "@", "--to", "unix:\(socket)"]
    }

    private static func isWindowID(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    private struct OSWindow: Decodable {
        struct Tab: Decodable { var windows: [Window] }
        struct Window: Decodable {
            var pid: Int
            var is_focused: Bool
        }
        var tabs: [Tab]
    }

    private static func front(_ terminal: TerminalProcess, socket: String, facts: TerminalFacts) -> FrontStep {
        let answer = facts.run(remote(terminal, socket: socket) + ["ls", "--match", "state:focused"])
        guard answer.status == 0, let windows = try? JSONDecoder().decode([OSWindow].self, from: Data(answer.output.utf8)) else {
            return .unknown(.unreadable(name))
        }
        let focused = windows.flatMap(\.tabs).flatMap(\.windows).filter(\.is_focused)
        guard focused.count == 1 else { return focused.isEmpty ? .unknown(.unreported(name)) : .unknown(.ambiguous) }
        guard let process = facts.process(focused[0].pid) else { return .unknown(.processesUnreadable) }
        guard let tty = process.tty else { return .unknown(.unreported(name)) }
        return .tty(tty)
    }
}
