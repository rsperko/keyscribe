import Carbon.HIToolbox
import KeyScribeKit

// Builds the character → keystroke index from the active layout via UCKeyTranslate, cached per input
// source so a dictation-sized insert doesn't re-scan 512 key/modifier combos per character. Dead keys are
// translated with kUCKeyTranslateNoDeadKeysMask so a dead key yields its standalone character rather than
// pending state; composed characters (é on US) stay off the index and fall back to payload events.
@MainActor
enum KeyboardLayout {
    private static var cachedIndex: KeyboardLayoutIndex?
    private static var cachedSourceId: String?

    static func currentIndex() -> KeyboardLayoutIndex? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        let sourceId = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        if let sourceId, sourceId == cachedSourceId, let cachedIndex { return cachedIndex }
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        let index = data.withUnsafeBytes { raw -> KeyboardLayoutIndex? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            return KeyboardLayoutIndex { keyCode, modifiers in
                translate(layout: layout, keyCode: keyCode, modifiers: modifiers, keyboardType: keyboardType)
            }
        }
        cachedSourceId = sourceId
        cachedIndex = index
        return index
    }

    private static func translate(layout: UnsafePointer<UCKeyboardLayout>, keyCode: Int,
                                  modifiers: Set<Modifier>, keyboardType: UInt32) -> String? {
        var modifierState: UInt32 = 0
        if modifiers.contains(.shift) { modifierState |= UInt32(shiftKey) }
        if modifiers.contains(.option) { modifierState |= UInt32(optionKey) }
        modifierState = (modifierState >> 8) & 0xFF
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), modifierState,
                                    keyboardType, UInt32(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                    characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
