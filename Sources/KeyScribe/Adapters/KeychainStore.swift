import Foundation
import Security

// BYOK secrets live in the Keychain; TOML stores only the `key_ref` (design.md §4.6,
// config_schema.md). A connection's key_ref is the Keychain account under one service.
//
// We use the legacy login keychain, not the data-protection keychain: under local self-signed
// signing (no Team ID) the data-protection keychain is unusable — the keychain-access-groups
// entitlement it needs makes AMFI SIGKILL the app at launch, and without it SecItem returns
// errSecMissingEntitlement. The login keychain's only downside is the interactive ACL prompt, which
// fires solely when the *secret data* is decrypted (`get`). Existence checks (`has`) ask for
// attributes only, never the data, so they never prompt — that is what the Settings UI uses.
enum KeychainStore {
    private static let service = "com.keyscribe.llm"

    private static func baseQuery(_ keyRef: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyRef,
        ]
    }

    // Returns whether the secret was actually stored. The caller must not mark a key "present" on a
    // false return: a discarded failure would show a saved-key badge while every later rewrite quietly
    // falls back to local for want of a key.
    @discardableResult
    static func set(_ secret: String, for keyRef: String) -> Bool {
        let data = Data(secret.utf8)
        let query = baseQuery(keyRef)
        // Always delete + re-add rather than SecItemUpdate: an update keeps the item's existing ACL, so
        // an item created by an earlier signature (e.g. a pre-cert ad-hoc build) keeps trusting that old
        // identity and every read prompts. Re-adding gives the item a fresh default ACL owned by the
        // current code signature, which can then decrypt it silently. Re-entering the key migrates a
        // stale item in one step.
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    // Existence only: returns attributes, never the secret data, so it does not trigger the Keychain
    // ACL prompt. Use this anywhere you only need "is a key stored?" (e.g. the Settings UI badges).
    static func has(_ keyRef: String) -> Bool {
        var query = baseQuery(keyRef)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    static func get(_ keyRef: String) -> String? {
        var query = baseQuery(keyRef)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let secret = String(data: data, encoding: .utf8)
        else { return nil }
        return secret
    }

    static func delete(_ keyRef: String) {
        SecItemDelete(baseQuery(keyRef) as CFDictionary)
    }
}
