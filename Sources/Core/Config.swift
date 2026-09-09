import Foundation

/// Runtime configuration.
///
/// The server host is **not** hardcoded in a committed source file. It is
/// resolved, in order, from:
///
///  1. `server_base_url` delivered by Firebase Remote Config — but only if its
///     host equals `allowedHostSuffix` or ends in `".<allowedHostSuffix>"`
///     (`isAllowedHost`). This is the "change the backend without a rebuild" path.
///  2. `MANTEL_BASE_URL` in a bundled `Secrets.plist` (git-ignored — see
///     `Secrets/Secrets.example.plist`).
///  3. The compiled-in placeholder below, so a fresh clone still builds and runs.
///
/// Mirrors the Android client's `secrets.properties` + `server_base_url` model.
enum Config {
    // MARK: - Fixed identifiers (safe to publish)

    /// App Group shared between the app and the Share Extension. Backs the shared
    /// credential keychain, the staged-file container, and the upload-state store.
    static let appGroupIdentifier = "group.com.eeinspired.mantel"

    /// Keychain access group (must match the `keychain-access-groups` entitlement,
    /// minus the team-id prefix Apple adds at runtime).
    static let keychainAccessGroup = "com.eeinspired.mantel.shared"

    /// Identifier of the background `URLSession` that carries every byte transfer.
    /// The same identifier is used from the app and the extension so either process
    /// can reattach to in-flight work.
    static let backgroundSessionIdentifier = "com.eeinspired.mantel.uploads"

    // MARK: - Server host

    /// Placeholder used when neither Remote Config nor `Secrets.plist` supplies a
    /// value. Not a real deployment.
    private static let fallbackBaseURL = URL(string: "https://nextcloud.example.com")!

    /// A Remote Config `server_base_url` is only honoured when its host is this
    /// value or a sub-domain of it. Keep it as tight as your DNS allows.
    static var allowedHostSuffix: String {
        secretsValue("MANTEL_ALLOWED_HOST_SUFFIX") ?? "example.com"
    }

    /// Set once at launch from `RemoteFlags.load()` when a valid override arrives.
    /// Written before any upload starts; read on multiple queues thereafter.
    nonisolated(unsafe) static var remoteOverrideBaseURL: URL?

    static var baseURL: URL {
        if let remoteOverrideBaseURL { return remoteOverrideBaseURL }
        if let raw = secretsValue("MANTEL_BASE_URL"), let url = URL(string: raw) { return url }
        return fallbackBaseURL
    }

    static var host: String { baseURL.host ?? allowedHostSuffix }

    /// Whether `candidate` is acceptable as a server host (exact match or
    /// sub-domain of `allowedHostSuffix`).
    static func isAllowedHost(_ candidate: String) -> Bool {
        let suffix = allowedHostSuffix.lowercased()
        let host = candidate.lowercased()
        return host == suffix || host.hasSuffix(".\(suffix)")
    }

    // MARK: - Secrets.plist

    /// Reads a string from a bundled `Secrets.plist`, falling back to
    /// `Secrets.example.plist` (both live in `Secrets/`). Returns nil for a
    /// missing or blank entry.
    private static func secretsValue(_ key: String) -> String? {
        for resource in ["Secrets", "Secrets.example"] {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "plist"),
                  let dict = NSDictionary(contentsOf: url) as? [String: Any],
                  let value = dict[key] as? String,
                  !value.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            return value
        }
        return nil
    }
}
