import Foundation
import os

/// Runtime configuration.
///
/// The server host is **not** hardcoded in a committed source file. It is
/// resolved once per process, in order, from:
///
///  1. A `server_base_url` cached from Firebase Remote Config on a previous run —
///     but only if it passes `isAllowed` (HTTPS, origin only, host on the
///     allowlist), so a compromised Remote Config cannot redirect the app (and the
///     app password) to an arbitrary server.
///  2. `MANTEL_BASE_URL` in a bundled `Secrets.plist` (git-ignored — see
///     `Secrets/Secrets.example.plist`).
///  3. The compiled-in placeholder below, so a fresh clone still builds and runs.
///
/// A validated Remote Config value is cached and used from the **next** launch on
/// — never swapped mid-session, so every request in a run uses one consistent host.
///
/// Mirrors the Android client's `secrets.properties` + `server_base_url` model.
enum Config {
    // MARK: - Fixed identifiers (safe to publish)

    /// App Group shared between the app and the Share Extension. Backs the shared
    /// credential keychain, the staged-file container, and the upload-state store.
    static let appGroupIdentifier = "group.com.eeinspired.mantel"

    /// Keychain access group, with the team-id prefix. A keychain query must name the group
    /// in full (`<TeamID>.com.eeinspired.mantel.shared`), so it's read from the Info.plist key
    /// that expands `$(AppIdentifierPrefix)`. `nil` (unsigned builds) falls back to the app's
    /// default group.
    static let keychainAccessGroup: String? = {
        let value = Bundle.main.object(forInfoDictionaryKey: "MantelKeychainAccessGroup") as? String
        guard let value, !value.hasPrefix("$("), !value.hasPrefix(".") else { return nil }
        return value
    }()

    /// Identifier of the app's background `URLSession`.
    static let appSessionIdentifier = "com.eeinspired.mantel.uploads"

    /// Identifier of the Share Extension's background `URLSession`. Apple's app-extension
    /// guidance requires a session identifier per process; the extension session sets
    /// `sharedContainerIdentifier`, so when the extension is gone the containing app is
    /// launched with this identifier and receives the completions.
    static let extensionSessionIdentifier = "com.eeinspired.mantel.uploads.share"

    /// Every background session identifier the app may be woken for.
    static let allSessionIdentifiers = [appSessionIdentifier, extensionSessionIdentifier]

    /// True when running inside the Share Extension (an `.appex` bundle).
    static let isExtension = Bundle.main.bundlePath.hasSuffix(".appex")

    /// The background session this process owns.
    static var ownSessionIdentifier: String {
        isExtension ? extensionSessionIdentifier : appSessionIdentifier
    }

    // MARK: - Server host

    /// Placeholder used when neither a cached Remote Config value nor `Secrets.plist`
    /// supplies one. Not a real deployment.
    private static let fallbackBaseURL = URL(string: "https://nextcloud.example.com")!

    /// Bundled default origin — from `Secrets.plist` (`MANTEL_BASE_URL`) at build time.
    static var defaultBaseURL: URL {
        if let raw = secretsValue("MANTEL_BASE_URL"), let url = URL(string: raw) { return url }
        return fallbackBaseURL
    }

    /// A Remote Config `server_base_url` is only honoured when its host is this
    /// value or a sub-domain of it. Keep it as tight as your DNS allows.
    static var allowedHostSuffix: String {
        secretsValue("MANTEL_ALLOWED_HOST_SUFFIX") ?? "example.com"
    }

    /// Resolved once, on first use, and then fixed for the life of the process.
    private static let resolvedBaseURL = OSAllocatedUnfairLock<URL>(initialState: resolveAtLaunch())

    static var baseURL: URL { resolvedBaseURL.withLock { $0 } }

    static var host: String { baseURL.host ?? allowedHostSuffix }

    /// Apply a Remote Config candidate if well-formed and allow-listed; cache it for
    /// the next launch. Never mutates `baseURL` for the current run.
    static func applyRemote(_ candidate: String?) {
        let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingTrailingSlashes() ?? ""
        if value.isEmpty || value == baseURL.absoluteString.trimmingTrailingSlashes() { return }
        guard isAllowed(value) else {
            if value != defaultBaseURL.absoluteString.trimmingTrailingSlashes() {
                let host = URL(string: value)?.host ?? ""
                Telemetry.shared.recordNonFatal(
                    NSError(domain: "Config", code: 0, userInfo: [
                        NSLocalizedDescriptionKey: "rejected server_base_url from Remote Config: host=\(host)",
                    ]),
                    context: "config_rejected_remote"
                )
            }
            return
        }
        sharedDefaults.set(value, forKey: cachedBaseURLKey)
        // Takes effect next launch via `resolveAtLaunch()`; do not mutate `baseURL` here.
    }

    /// True for an HTTPS origin (default port, no path beyond `/`, query, fragment or credentials)
    /// whose host is `allowedHostSuffix` or a sub-domain of it.
    static func isAllowed(_ candidate: String) -> Bool {
        guard let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              isAllowedHost(host),
              components.port == nil || components.port == 443,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil,
              components.user == nil,
              components.password == nil
        else { return false }
        return true
    }

    /// Whether `candidate` is acceptable as a server host (exact match or
    /// sub-domain of `allowedHostSuffix`).
    static func isAllowedHost(_ candidate: String) -> Bool {
        let suffix = allowedHostSuffix.lowercased()
        let host = candidate.lowercased()
        return host == suffix || host.hasSuffix(".\(suffix)")
    }

    // MARK: - Internals

    private static let cachedBaseURLKey = "remote_base_url"

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    private static func resolveAtLaunch() -> URL {
        let resolved: URL = if let cached = sharedDefaults.string(forKey: cachedBaseURLKey),
                               isAllowed(cached), let url = URL(string: cached) {
            url
        } else {
            defaultBaseURL
        }
        Telemetry.shared.setKey("server_host", resolved.host ?? "")
        return resolved
    }

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

extension String {
    func trimmingTrailingSlashes() -> String {
        var result = self
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
