import Foundation

extension ScriptedTerminalRoute {
    public static let iterm = ScriptedTerminalRoute(
        name: "iTerm", app: "com.googlecode.iterm2", helperPrefix: "iTermServer-",
        front: "return tty of current session of current window", body: itermBody, placeScript: """
        set sep to character id 9
        set out to ""
        repeat with w in windows
            set windowId to id of w
            repeat with t from 1 to count of tabs of w
                repeat with s in sessions of tab t of w
                    set override to ""
                    try
                        tell s to set override to (variable named "tab.titleOverride")
                    end try
                    if override is missing value then set override to ""
                    set out to out & windowId & sep & t & sep & (tty of s) & sep & override & linefeed
                end repeat
            end repeat
        end repeat
        return out
        """, placesFrom: ITermPlaces.layer)

    static let itermBody = """
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
        """
}

enum ITermPlaces {
    @Sendable static func layer(answer: String, ttys: [String], surface: String) -> PlaceLayer? {
        var sessions: [String: (tab: String, override: String)] = [:]
        for line in answer.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { continue }
            sessions[fields[2]] = ("iterm#tab:\(fields[0]):\(fields[1])", fields[3])
        }
        guard let tty = ttys.first(where: { sessions[$0] != nil }), let session = sessions[tty] else { return nil }
        var layer = PlaceLayer(containers: [session.tab])
        if let text = TerminalPlaces.userSet(session.override) {
            layer.labels.append(.init(text: text, level: .tab, container: session.tab, surface: surface, term: "tab"))
        }
        return layer
    }
}
