import Foundation

public struct ScriptedTerminalRoute: TerminalRoute {
    public let app: String
    let helperPrefix: String?
    let body: String
    public let environmentKeys: [String] = []

    public func owns(_ process: TerminalProcess) -> Bool {
        process.app == app || helperPrefix.map(process.name.hasPrefix) == true
    }

    public func actions(terminal: TerminalProcess, inner: ArraySlice<TerminalProcess>) -> [OpenAction] {
        open(pid: terminal.pid, ttys: TerminalRoutes.ttys(of: inner))
    }

    public func open(pid: Int, ttys: [String]) -> [OpenAction] {
        guard !ttys.isEmpty else { return [.activate(app: app, pid: pid)] }
        let wanted = "set wanted to {" + ttys.map(AppleScriptText.literal).joined(separator: ", ") + "}\n"
        return [.select(.script(app: app, pid: pid, body: wanted + body)), .activate(app: app, pid: pid)]
    }

    public static let ghostty = ScriptedTerminalRoute(app: "com.mitchellh.ghostty", helperPrefix: nil, body: """
        repeat with candidate in wanted
            set found to (every terminal whose tty is (contents of candidate))
            if (count of found) > 0 then
                focus (item 1 of found)
                return true
            end if
        end repeat
        return false
        """)

    public static let terminal = ScriptedTerminalRoute(app: "com.apple.Terminal", helperPrefix: nil, body: """
        repeat with w from 1 to count of windows
            repeat with t from 1 to count of tabs of window w
                if wanted contains (tty of tab t of window w) then
                    set selected of tab t of window w to true
                    if miniaturized of window w then set miniaturized of window w to false
                    set index of window w to 1
                    return true
                end if
            end repeat
        end repeat
        return false
        """)

    public static let iterm = ScriptedTerminalRoute(app: "com.googlecode.iterm2", helperPrefix: "iTermServer-", body: """
        set found to missing value
        repeat with w from 1 to count of windows
            repeat with t from 1 to count of tabs of window w
                repeat with s from 1 to count of sessions of tab t of window w
                    if wanted contains (tty of session s of tab t of window w) then
                        set found to {id of window w, t, s}
                        exit repeat
                    end if
                end repeat
                if found is not missing value then exit repeat
            end repeat
            if found is not missing value then exit repeat
        end repeat
        if found is missing value then return false
        set {windowId, t, s} to found
        select tab t of window id windowId
        select session s of tab t of window id windowId
        select window id windowId
        return true
        """)
}

public enum AppleScriptText {
    public static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
