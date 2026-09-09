import FirebaseCore
import FirebaseRemoteConfig
import Foundation

/// Immutable read of every feature flag, taken once per launch (Requirements §13.0).
struct FlagSnapshot: Equatable {
    var galleryEnabled = false
    /// Independent of `galleryEnabled` and defaults off — a kill switch for the one
    /// destructive action.
    var deleteEnabled = false
}

/// Firebase Remote Config wrapper.
///
/// This is the single third-party dependency on iOS: Remote Config only — no
/// Crashlytics, no Analytics (those are covered first-party by `Telemetry`).
/// Flags ship bundled as **off**; a successful fetch can turn them on with no
/// rebuild or reinstall — the right fit for a TestFlight / ad-hoc family tool.
/// Values are read once at launch (`load()`); a change takes effect next start.
///
/// Keys mirror the Android client:
/// - `gallery_enabled` (bool)
/// - `delete_enabled` (bool)
/// - `server_base_url` (string) — applied to `Config.remoteOverrideBaseURL` only
///   when its host passes `Config.isAllowedHost`.
enum RemoteFlags {
    static let keyGalleryEnabled = "gallery_enabled"
    static let keyDeleteEnabled = "delete_enabled"
    static let keyServerBaseURL = "server_base_url"

    private static let minFetchInterval: TimeInterval = 3600

    /// Safe to call more than once. Skips configuration when there is no
    /// `GoogleService-Info.plist` in the bundle, so the app still runs (flags just
    /// stay at their bundled `false`) before Firebase is wired up.
    static func configureIfPossible() {
        guard FirebaseApp.app() == nil else { return }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            return
        }
        FirebaseApp.configure()
    }

    static func load() async -> FlagSnapshot {
        configureIfPossible()
        guard FirebaseApp.app() != nil else { return FlagSnapshot() }

        let config = RemoteConfig.remoteConfig()
        config.setDefaults([
            keyGalleryEnabled: false as NSObject,
            keyDeleteEnabled: false as NSObject,
            keyServerBaseURL: "" as NSObject,
        ])
        let settings = RemoteConfigSettings()
        settings.minimumFetchInterval = minFetchInterval
        config.configSettings = settings

        _ = try? await config.fetchAndActivate()

        applyServerBaseURLOverride(config[keyServerBaseURL].stringValue)

        return FlagSnapshot(
            galleryEnabled: config[keyGalleryEnabled].boolValue,
            deleteEnabled: config[keyDeleteEnabled].boolValue
        )
    }

    /// Honour a Remote Config `server_base_url` only when it is a well-formed
    /// https URL whose host is allowed (`Config.isAllowedHost`).
    private static func applyServerBaseURLOverride(_ raw: String?) {
        guard let raw, !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              Config.isAllowedHost(host)
        else { return }
        Config.remoteOverrideBaseURL = url
    }
}
