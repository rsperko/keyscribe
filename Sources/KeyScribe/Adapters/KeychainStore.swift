import Foundation
import Security
import KeyScribeKit

// BYOK secrets live in the Keychain; TOML stores only the `key_ref`.
//
// Use the legacy login keychain because dev builds are self-signed. `has` reads attributes only, so
// Settings badges do not trigger the ACL prompt that decrypting secret data can show.
//
// `CachingSecretStore` keeps rewrite attempts from decrypting the same key repeatedly.
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

    @discardableResult
    static func set(_ secret: String, for keyRef: String) -> Bool {
        cache.set(secret, for: keyRef)
    }

    static func get(_ keyRef: String) -> String? {
        cache.get(keyRef)
    }

    static func lookup(_ keyRef: String) -> SecretLookup {
        cache.lookup(keyRef)
    }

    static func delete(_ keyRef: String) {
        cache.delete(keyRef)
    }

    // Erase every BYOK secret under this variant's service.
    @discardableResult
    static func deleteAll() -> Int {
        cache.deleteAll()
    }

    // Existence only: returns attributes, never secret data.
    static func has(_ keyRef: String) -> Bool {
        var query = baseQuery(keyRef)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    // Update in place so there is never a window where the key is absent: a crash mid-write can neither
    // strand the stored secret (the old delete-then-add did) nor leak a `.tmp.<UUID>` backup item.
    // `SecItemUpdate` errors `errSecItemNotFound` only when nothing is stored yet — the one case that
    // needs a fresh `SecItemAdd`. Data-only update: `kSecAttrAccessible` is set once at creation, and
    // updating it on a legacy login-keychain item can return `errSecParam`, misread here as a save failure.
    private static func rawSet(_ secret: String, for keyRef: String, cachedOld: String?) -> Bool {
        let data = Data(secret.utf8)
        let query = baseQuery(keyRef)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    // `errSecItemNotFound` is a genuine absence; any other non-success (locked keychain, declined ACL) is a
    // denial the caller must not read as "no key stored".
    private static func rawGet(_ keyRef: String) -> SecretLookup {
        var query = baseQuery(keyRef)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else { return .absent }
            return .found(secret)
        case errSecItemNotFound:
            return .absent
        default:
            return .denied(status: status)
        }
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
