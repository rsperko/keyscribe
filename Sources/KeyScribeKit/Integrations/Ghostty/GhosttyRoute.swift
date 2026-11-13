import Foundation

extension ScriptedTerminalRoute {
    public static let ghostty = ScriptedTerminalRoute(
        name: "Ghostty", apps: ["com.mitchellh.ghostty"], helperPrefix: nil,
        front: "return tty of focused terminal of selected tab of front window", body: """
        repeat with candidate in wanted
            set found to (every terminal whose tty is (contents of candidate))
            if (count of found) > 0 then
                focus (item 1 of found)
                return true
            end if
        end repeat
        return false
        """, placeScript: """
        set sep to character id 9
        set out to ""
        repeat with w in windows
            set out to out & "W" & sep & (id of w) & sep & (count of tabs of w) & sep & (count of terminals of w) & linefeed
            repeat with t in tabs of w
                set out to out & "T" & sep & (id of t) & sep & (name override of t) & sep & (tty of focused terminal of t) & linefeed
            end repeat
            repeat with s in terminals of w
                set out to out & "S" & sep & (id of s) & sep & (tty of s) & sep & (name override of s) & linefeed
            end repeat
        end repeat
        return out
        """, placesFrom: GhosttyPlaces.layer)
}

enum GhosttyPlaces {
    @Sendable static func layer(answer: String, ttys: [String], surface: String) -> PlaceLayer? {
        var tabs: [String: (id: String, override: String)] = [:]
        var terminals: [String: (id: String, override: String)] = [:]
        var single = false
        for line in answer.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch (fields.first, fields.count) {
            case ("W", 4): single = fields[2] == fields[3]
            case ("T", 4) where single: tabs[fields[3]] = (fields[1], fields[2])
            case ("S", 4): terminals[fields[2]] = (fields[1], fields[3])
            default: continue
            }
        }
        guard let tty = ttys.first(where: { terminals[$0] != nil }), let terminal = terminals[tty] else { return nil }
        let key = "ghostty"
        var layer = PlaceLayer(containers: ["\(key)#terminal:\(terminal.id)"])
        if let text = TerminalPlaces.userSet(terminal.override) {
            layer.labels.append(.init(text: text, level: .pane, container: layer.containers[0], surface: surface, term: "terminal"))
        }
        if let tab = tabs[tty] {
            layer.containers.append("\(key)#tab:\(tab.id)")
            if let text = TerminalPlaces.userSet(tab.override) {
                layer.labels.append(.init(text: text, level: .tab, container: layer.containers[1], surface: surface, term: "tab"))
            }
        }
        return layer
    }
}
