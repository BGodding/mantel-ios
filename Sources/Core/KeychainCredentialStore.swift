import Foundation
import Security

/// Credential storage backed by iOS Keychain Services (`kSecClassGenericPassword`)
/// — first-party, no dependency (Requirements §4 / §8).
///
/// The item is written to a shared keychain access group so the Share Extension
/// can read the same credential the app stored. Protection class is
/// `AfterFirstUnlockThisDeviceOnly` (so it never migrates to another device via a backup)
/// so a background upload started from the extension can still read it while the screen
/// is locked (mirrors the Android decision not to require
/// an unlocked device — see `CredentialStore` notes there).
///
/// Read failures are told apart, as on Android:
/// - **permanent** — the blob can never be read again (undecodable / tampered): report,
///   clear the slot, treat as logged out;
/// - **transient** — the OS said "not now" (device not yet unlocked, keychain busy): report,
///   but keep the blob so a later read can succeed. Clearing here would sign the user out
///   over a hiccup.
struct KeychainCredentialStore {
    private let service = "com.eeinspired.mantel.credentials"
    private let account = "primary"
    private let accessGroup: String?

    /// Pass `nil` to skip the access group (useful for unit tests / simulators
    /// without the entitlement); production call sites pass `Config.keychainAccessGroup`.
    init(accessGroup: String? = Config.keychainAccessGroup) {
        self.accessGroup = accessGroup
    }

    /// Returns `false` (after reporting) if the credential could not be stored, so the
    /// caller doesn't tell the user they're signed in when the next launch would find nothing.
    @discardableResult
    func save(_ credentials: Credentials) -> Bool {
        let blob = CredentialBlob(
            username: credentials.username,
            appPassword: credentials.appPassword,
            userId: credentials.userId
        )
        guard let data = try? JSONEncoder().encode(blob) else { return false }

        // Update in place when the item exists (never a window with no credential stored),
        // add it otherwise. The attributes also migrate items written with the older,
        // backup-portable accessibility class.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery().merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            Telemetry.shared.recordNonFatal(
                NSError(domain: "CredentialStore", code: Int(status), userInfo: [
                    NSLocalizedDescriptionKey: "credential save failed (OSStatus \(status))",
                ]),
                context: "credential_store"
            )
            return false
        }
        return true
    }

    func load() -> Credentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return nil
        default:
            transientFailure(status)
            return nil
        }
        guard let data = result as? Data,
              let blob = try? JSONDecoder().decode(CredentialBlob.self, from: data)
        else {
            permanentFailure()
            return nil
        }
        // Blobs written before `userId` existed fall back to the login name.
        return Credentials(
            username: blob.username,
            appPassword: blob.appPassword,
            userId: blob.userId.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// The stored blob can never be read again — report it and start over signed out.
    private func permanentFailure() {
        Telemetry.shared.setKey("credential_failure", "permanent")
        Telemetry.shared.recordNonFatal(
            NSError(domain: "CredentialStore", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "credentials unreadable, cleared",
            ]),
            context: "credential_store"
        )
        clear()
    }

    /// Keychain hiccup (locked, busy): report, but keep the blob so the next read can retry.
    private func transientFailure(_ status: OSStatus) {
        Telemetry.shared.setKey("credential_failure", "transient:\(status)")
        Telemetry.shared.recordNonFatal(
            NSError(domain: "CredentialStore", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "credential read failed, kept (OSStatus \(status))",
            ]),
            context: "credential_store"
        )
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

/// Compact on-disk shape: single-letter JSON keys keep the blob small.
private struct CredentialBlob: Codable {
    let username: String
    let appPassword: String
    /// Absent in blobs written before the server uid was stored.
    let userId: String?

    enum CodingKeys: String, CodingKey {
        case username = "u"
        case appPassword = "p"
        case userId = "i"
    }
}
