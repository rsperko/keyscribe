import Foundation

/// Decodes the Chromium `org.chromium.web-custom-data` pasteboard flavor — a "pickle" of length-prefixed
/// UTF-16 key/value pairs — and reads the VS Code / Monaco selection metadata a copy from that editor
/// family carries. Used to tell a real selection from an empty-selection whole-line copy when
/// Accessibility cannot report the selection (Electron/Chromium).
public enum WebCustomData {
    /// The pickle as a `[key: value]` map. Malformed or truncated input yields whatever parsed cleanly
    /// before the defect — never a crash.
    public static func decode(_ data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var offset = 0
        func readUInt32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        func readString() -> String? {
            guard let count = readUInt32() else { return nil }
            let byteCount = Int(count) * 2
            guard offset + byteCount <= bytes.count else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(Int(count))
            var index = offset
            while index < offset + byteCount {
                units.append(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
                index += 2
            }
            offset += byteCount
            while offset % 4 != 0 { offset += 1 }
            return String(decoding: units, as: UTF16.self)
        }
        _ = readUInt32()  // payload-size prefix, unused
        guard let pairCount = readUInt32() else { return [:] }
        var map: [String: String] = [:]
        for _ in 0..<pairCount {
            guard let key = readString(), let value = readString() else { break }
            map[key] = value
        }
        return map
    }

    /// `isFromEmptySelection` from a VS Code-family `vscode-editor-data` entry. `nil` ⇒ the copy carries
    /// no such entry, i.e. it is not from a VS Code-family editor (Obsidian, Chrome, plain text, …).
    public static func vscodeIsFromEmptySelection(_ data: Data?) -> Bool? {
        guard let data,
            let json = decode(data)["vscode-editor-data"],
            let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        return object["isFromEmptySelection"] as? Bool
    }
}
