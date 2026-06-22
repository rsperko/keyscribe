import Foundation
import Security

// BYOK secrets live in the Keychain; TOML stores only the `key_ref` (design.md §4.6,
// config_schema.md). A connection's key_ref is the Keychain account under one service.
enum KeychainStore {
    private static let service = "com.keyscribe.llm"

    static func set(_ secret: String, for keyRef: String) {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyRef,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func get(_ keyRef: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyRef,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let secret = String(data: data, encoding: .utf8)
        else { return nil }
        return secret
    }

    static func delete(_ keyRef: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyRef,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
