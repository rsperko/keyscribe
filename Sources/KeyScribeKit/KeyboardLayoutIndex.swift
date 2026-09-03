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
    private let shortcutByCharacter: [Character: Int]
    private let shortcutByKeyCode: [Int: Character]

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

        var byCharacter: [Character: Int] = [:]
        var byKeyCode: [Int: Character] = [:]
        for keyCode in Self.scannedKeyCodes {
            guard SpecialKey(keyCode: keyCode) == nil,
                  let produced = produce(keyCode, [.command]) ?? produce(keyCode, []),
                  produced.count == 1,
                  let character = produced.first,
                  let identity = BaseKey.normalized(character)
            else { continue }
            byKeyCode[keyCode] = identity
            if byCharacter[identity] == nil { byCharacter[identity] = keyCode }
        }
        self.shortcutByCharacter = byCharacter
        self.shortcutByKeyCode = byKeyCode
    }

    public func stroke(for character: Character) -> LayoutKeystroke? {
        if let direct = strokes[character] { return direct }
        if character == "\n" { return strokes["\r"] }
        return nil
    }

    public func shortcutKeyCode(for character: Character) -> Int? { shortcutByCharacter[character] }

    public func shortcutCharacter(forKeyCode keyCode: Int) -> Character? { shortcutByKeyCode[keyCode] }

    private static func isTypeable(_ character: Character) -> Bool {
        if character == "\r" || character == "\t" { return true }
        return !character.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}

extension KeyboardLayoutIndex {
    public static let ansiUS = KeyboardLayoutIndex { keyCode, modifiers in
        guard modifiers.isEmpty else { return nil }
        return ansiUSUnshifted[keyCode].map(String.init)
    }

    private static let ansiUSUnshifted: [Int: Character] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i",
        38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r",
        1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\",
        41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 10: "\u{a7}",
    ]
}
