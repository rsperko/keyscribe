public enum TypedText {
    // CGEvent's unicode payload truncates past 20 UTF-16 units, so this is an API ceiling, not a tuning knob.
    public static let maxUnitsPerKeyEvent = 20

    // One grapheme cluster per event, never more. Payload events are the FALLBACK for characters the active
    // layout cannot produce as a real keystroke (KeyboardLayoutIndex): a translating target — a VM
    // hypervisor, a remote client — reads only the event's virtual key and drops the payload no matter its
    // length (observed in VMware Fusion: keycode 0, one literal "a" per event, even one character at a
    // time), so this path lands in native apps only. A cluster too large for one event is split rather than
    // truncated, never between the halves of a surrogate pair.
    public static func keyEventChunks(_ text: String, maxUnits: Int = maxUnitsPerKeyEvent) -> [[UInt16]] {
        precondition(maxUnits >= 2)
        var chunks: [[UInt16]] = []
        for character in text {
            let units = Array(character.utf16)
            if units.count > maxUnits {
                chunks.append(contentsOf: splitOversized(units, maxUnits: maxUnits))
            } else {
                chunks.append(units)
            }
        }
        return chunks
    }

    private static func splitOversized(_ units: [UInt16], maxUnits: Int) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + maxUnits, units.count)
            if end < units.count, isHighSurrogate(units[end - 1]) { end -= 1 }
            chunks.append(Array(units[start..<end]))
            start = end
        }
        return chunks
    }

    private static func isHighSurrogate(_ unit: UInt16) -> Bool { (0xD800...0xDBFF).contains(unit) }
}
