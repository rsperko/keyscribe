import Foundation
import Security
import KeyScribeKit

// BYOK secrets live in the Keychain; TOML stores only the `key_ref` (design.md §4.6,
// config_schema.md). A connection's key_ref is the Keychain account under one service.
//
// We use the legacy login keychain, not the data-protection keychain: under local self-signed
// signing (no Team ID) the data-protection keychain is unusable — the keychain-access-groups
// entitlement it needs makes AMFI SIGKILL the app at launch, and without it SecItem returns
// errSecMissingEntitlement. The login keychain's only downside is the interactive ACL prompt, which
// fires solely when the *secret data* is decrypted (`get`). Existence checks (`has`) ask for
// attributes only, never the data, so they never prompt — that is what the Settings UI uses.
//
// A `CachingSecretStore` fronts the raw SecItem ops so a key is decrypted at most once per process
// (get on every rewrite attempt was the hot-path prompt risk). Every mutation routes through the
// cache; `has` stays a direct pass-through so the Settings badges reflect the live keychain.
enum KeychainStore {
    // Per-variant service so the KeyScribeDev build keeps its BYOK keys separate and never fights the
    // production app over a shared item's ACL.
    private static let service = AppVariant(bundleID: Bundle.main.bundleIdentifier).keychainService

    private static let cache = CachingSecretStore(backend: CachingSecretStore.Backend(
        load: { rawGet($0) },
        save: { rawSet($0, for: $1, cachedOld: $2) },
        remove: { rawDelete($0) },
        removeAll: { rawDeleteAll() }
    ))

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
        cache.set(secret, for: keyRef)
    }

    static func get(_ keyRef: String) -> String? {
        cache.get(keyRef)
    }

    static func delete(_ keyRef: String) {
        cache.delete(keyRef)
    }

    // Erase every BYOK secret under this variant's service in one call (no account ⇒ all items match).
    // Variant-scoped, so the dev build never touches the production app's keys. Backs the "Erase All
    // KeyScribe Data" action. The count is read with attributes only (no ACL prompt), for an honest
    // action message; deletion needs no data access either.
    @discardableResult
    static func deleteAll() -> Int {
        cache.deleteAll()
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

    private static func rawSet(_ secret: String, for keyRef: String, cachedOld: String?) -> Bool {
        let data = Data(secret.utf8)
        let query = baseQuery(keyRef)
        // Rollback backup: reuse the cached secret when warm so a re-save skips the decrypt/prompt.
        let oldData = cachedOld.map { Data($0.utf8) } ?? existingData(query)
        let tempRef = "\(keyRef).tmp.\(UUID().uuidString)"
        var temp = baseQuery(tempRef)
        temp[kSecValueData as String] = data
        temp[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        guard SecItemAdd(temp as CFDictionary, nil) == errSecSuccess else { return false }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        SecItemDelete(baseQuery(tempRef) as CFDictionary)
        if ok { return true }
        if let oldData {
            var restore = query
            restore[kSecValueData as String] = oldData
            restore[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            _ = SecItemAdd(restore as CFDictionary, nil)
        }
        return false
    }

    private static func existingData(_ query: [String: Any]) -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func rawGet(_ keyRef: String) -> String? {
        var query = baseQuery(keyRef)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let secret = String(data: data, encoding: .utf8)
        else { return nil }
        return secret
    }

    private static func rawDelete(_ keyRef: String) {
        SecItemDelete(baseQuery(keyRef) as CFDictionary)
    }

    private static func rawDeleteAll() -> Int {
        let countQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let count = SecItemCopyMatching(countQuery as CFDictionary, &result) == errSecSuccess
            ? ((result as? [[String: Any]])?.count ?? 0) : 0
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        return count
    }
}
