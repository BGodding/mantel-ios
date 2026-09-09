import Foundation
import Security

/// Credential storage backed by iOS Keychain Services (`kSecClassGenericPassword`)
/// — first-party, no dependency (Requirements §4 / §8).
///
/// The item is written to a shared keychain access group so the Share Extension
/// can read the same credential the app stored. Protection class is
/// `AfterFirstUnlock` so a background upload started from the extension can still
/// read it while the screen is locked (mirrors the Android decision not to require
/// an unlocked device — see `CredentialStore` notes there).
///
/// Any read failure (item missing, decode failure, OS error) is treated as
/// "logged out" and clears the slot.
struct KeychainCredentialStore {
    private let service = "com.eeinspired.mantel.credentials"
    private let account = "primary"
    private let accessGroup: String?

    /// Pass `nil` to skip the access group (useful for unit tests / simulators
    /// without the entitlement); production call sites pass `Config.keychainAccessGroup`.
    init(accessGroup: String? = Config.keychainAccessGroup) {
        self.accessGroup = accessGroup
    }

    func save(_ credentials: Credentials) {
        let blob = try? JSONEncoder().encode(
            CredentialBlob(username: credentials.username, appPassword: credentials.appPassword)
        )
        guard let data = blob else { return }

        let delete = baseQuery()
        SecItemDelete(delete as CFDictionary)

        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    func load() -> Credentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let blob = try? JSONDecoder().decode(CredentialBlob.self, from: data)
        else {
            if status != errSecItemNotFound { clear() }
            return nil
        }
        return Credentials(username: blob.username, appPassword: blob.appPassword)
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

/// Compact on-disk shape: single-letter JSON keys keep the encrypted blob small.
private struct CredentialBlob: Codable {
    let username: String
    let appPassword: String

    enum CodingKeys: String, CodingKey {
        case username = "u"
        case appPassword = "p"
    }
}
