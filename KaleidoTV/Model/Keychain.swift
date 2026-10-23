import Foundation
import Security

/// Paid-service links and logins, kept in the Keychain. On iPhone and iPad they are tied to this device
/// (not synced to iCloud, not included in backups) and only readable after the first unlock.
enum Keychain {
    private static let service = "KaleidoTV.sources"

    static func save(_ secret: [String: String], for id: String) throws {
        let data = try JSONEncoder().encode(secret)
        delete(id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw FetchError("Couldn't store the details securely (Keychain error \(status))")
        }
    }

    static func load(_ id: String) throws -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let secret = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw FetchError("The saved login for this source is missing; remove it and add it again")
        }
        return secret
    }

    static func delete(_ id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
