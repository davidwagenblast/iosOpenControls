import Foundation
import Security

enum KeychainError: Error {
    case status(OSStatus)
}

/// Minimal generic-password wrapper. `synchronizable` items travel through iCloud
/// Keychain (used for the parent's signing key so a new parent device can take over).
enum Keychain {
    private static let service = "OpenControls"

    static func set(_ data: Data, account: String, synchronizable: Bool = false) throws {
        var query = baseQuery(account: account, synchronizable: synchronizable)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func get(account: String, synchronizable: Bool = false) -> Data? {
        var query = baseQuery(account: account, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func delete(account: String, synchronizable: Bool = false) {
        SecItemDelete(baseQuery(account: account, synchronizable: synchronizable) as CFDictionary)
    }

    private static func baseQuery(account: String, synchronizable: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable
        ]
    }
}
