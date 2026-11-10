import Foundation

extension ScriptedTerminalRoute {
    public static let terminal = ScriptedTerminalRoute(
        name: "Terminal", app: "com.apple.Terminal", helperPrefix: nil, front: "return tty of selected tab of front window", body: """
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
}
