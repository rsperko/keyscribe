public struct LayoutKeystroke: Equatable, Sendable {
    public var keyCode: Int
    public var modifiers: Set<Modifier>

    public init(keyCode: Int, modifiers: Set<Modifier> = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Character → physical keystroke over the active keyboard layout, so type insertion can post events a
/// translating target (VM hypervisor, remote client) reads by virtual key. Simpler combos are indexed
/// first so a character reachable both plain and shifted types plain; a production that isn't exactly one
/// character (a dead-key artifact) can't correspond to one keystroke and is skipped; control characters
/// are never typeable — a transcript character must not fire an editing key like delete or escape —
/// except return and tab, which are how "\n"/"\t" land as real keystrokes.
public struct KeyboardLayoutIndex: Sendable {
    private let strokes: [Character: LayoutKeystroke]

    public static let scannedKeyCodes = 0..<128
    private static let modifierCombos: [Set<Modifier>] = [[], [.shift], [.option], [.shift, .option]]

    public init(produce: (Int, Set<Modifier>) -> String?) {
        var strokes: [Character: LayoutKeystroke] = [:]
        for modifiers in Self.modifierCombos {
            for keyCode in Self.scannedKeyCodes {
                guard let produced = produce(keyCode, modifiers),
                      produced.count == 1,
                      let character = produced.first,
                      Self.isTypeable(character),
                      strokes[character] == nil
                else { continue }
                strokes[character] = LayoutKeystroke(keyCode: keyCode, modifiers: modifiers)
            }
        }
        self.strokes = strokes
    }

    public func stroke(for character: Character) -> LayoutKeystroke? {
        if let direct = strokes[character] { return direct }
        if character == "\n" { return strokes["\r"] }
        return nil
    }

    private static func isTypeable(_ character: Character) -> Bool {
        if character == "\r" || character == "\t" { return true }
        return !character.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
