import Foundation

enum CodexJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }

    static func data(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 9.0e15 else { return nil }
        return number.intValue
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    static func clean(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
    }
}
