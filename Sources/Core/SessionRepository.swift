import Foundation
import Observation

/// Result of the launch-time credential check (Requirements §4).
enum Bootstrap: Equatable {
    case needsLogin
    case revoked(String)
    case ready(offlineNotice: String?)
}

enum LoginOutcome: Equatable {
    case success(UserInfo)
    case invalidCredentials
    case unreachable
    case serverProblem(Int)
    /// The server accepted the credential but it couldn't be stored on this device.
    case storageFailed
}

enum RefreshOutcome: Equatable {
    case success([Frame])
    case sessionExpired
    case unreachable
    case serverProblem(Int)
}

enum FolderOutcome: Equatable {
    case success([RemoteItem])
    case sessionExpired
    case unreachable
    case serverProblem(Int)
}

enum DeleteOutcome: Equatable {
    case success
    case sessionExpired
    case forbidden
    case alreadyGone
    case unreachable
    case serverProblem(Int)
}

extension Notification.Name {
    /// Posted after `SessionRepository.logOut()` so UI-layer caches (thumbnails, downloads
    /// of private family photos) can drop what they hold.
    static let mantelDidSignOut = Notification.Name("com.eeinspired.mantel.didSignOut")
}

/// Single owner of session state: keychain credentials, the live/cached
/// destination list, and the "am I still logged in" check.
///
/// There is no local database (Requirements §9). The frame list is fetched live
/// every time and only *cached* for instant display — the server is always the
/// source of truth. The cache lives in the shared App Group defaults so the
/// Share Extension can show the same list without a round-trip.
@MainActor
@Observable
final class SessionRepository {
    private let client = NextcloudClient()
    private let store = KeychainCredentialStore()
    private let defaults = UserDefaults(suiteName: Config.appGroupIdentifier) ?? .standard

    private var credentials: Credentials?

    /// The server's canonical uid — what the WebDAV paths are keyed by (not the typed login name).
    var userId: String? {
        credentials?.userId ?? defaults.string(forKey: Keys.userId)
    }

    /// Last frame the user uploaded to — a pure UX convenience, never authoritative (§6/§9).
    var lastDestinationID: String? {
        get { defaults.string(forKey: Keys.lastDestination) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.lastDestination)
            } else {
                defaults.removeObject(forKey: Keys.lastDestination)
            }
        }
    }

    /// Credentials for the current session, if signed in — used by the uploader and
    /// the authed image loader.
    func currentCredentials() -> Credentials? {
        if let credentials { return credentials }
        let loaded = store.load()
        credentials = loaded
        return loaded
    }

    func bootstrap() async -> Bootstrap {
        guard let stored = store.load() else { return .needsLogin }
        credentials = stored
        var check = await client.validateSession(stored)
        if case .unauthorized = check {
            // A 401 from a proxy or captive portal must not sign the user out (and, before,
            // discard their queued uploads): ask once more before believing it.
            try? await Task.sleep(for: .seconds(2))
            check = await client.validateSession(stored)
        }
        switch check {
        case let .success(user):
            // Installs that stored only the typed login name learn their real uid here.
            let resolved = user.id.isEmpty ? stored.userId : user.id
            var current = stored
            if resolved != stored.userId {
                current = Credentials(
                    username: stored.username,
                    appPassword: stored.appPassword,
                    userId: resolved
                )
                store.save(current)
            }
            credentials = current
            defaults.set(current.userId, forKey: Keys.userId)
            return .ready(offlineNotice: nil)
        case .unauthorized:
            logOut(wipeUploads: false)
            Telemetry.shared.event(Telemetry.Events.sessionRevoked, ["at": "launch"])
            return .revoked(Messages.sessionRevoked)
        case .networkError:
            return .ready(offlineNotice: Messages.offlineCached)
        case .serverError:
            return .ready(offlineNotice: Messages.serverCached)
        case let .malformed(detail):
            Telemetry.shared.recordAPIDrift("bootstrap:/cloud/user", detail)
            return .ready(offlineNotice: Messages.serverCached)
        }
    }

    func logIn(username: String, appPassword: String) async -> LoginOutcome {
        let typed = Credentials(
            username: username.trimmingCharacters(in: .whitespaces),
            appPassword: appPassword
        )
        switch await client.validateSession(typed) {
        case let .success(user):
            let creds = Credentials(
                username: typed.username,
                appPassword: typed.appPassword,
                userId: user.id.isEmpty ? typed.username : user.id
            )
            // A different account than last time must not inherit the previous account's
            // paused uploads (kept across a revoked session, wiped on an explicit sign-out).
            if let previous = defaults.string(forKey: Keys.userId), previous != creds.userId {
                UploadCoordinator.shared.cancelAllAndWipe(credentials: nil)
            }
            guard store.save(creds) else { return .storageFailed }
            credentials = creds
            defaults.set(creds.userId, forKey: Keys.userId)
            Telemetry.shared.event(Telemetry.Events.loginSuccess)
            return .success(user)
        case .unauthorized:
            Telemetry.shared.event(Telemetry.Events.loginFailure, ["reason": "invalid_credentials"])
            return .invalidCredentials
        case .networkError:
            Telemetry.shared.event(Telemetry.Events.loginFailure, ["reason": "unreachable"])
            return .unreachable
        case let .serverError(code):
            Telemetry.shared.event(Telemetry.Events.loginFailure, ["reason": "server", "code": code])
            return .serverProblem(code)
        case let .malformed(detail):
            Telemetry.shared.event(Telemetry.Events.loginFailure, ["reason": "malformed"])
            Telemetry.shared.recordAPIDrift("login:/cloud/user", detail)
            return .serverProblem(0)
        }
    }

    /// A 401 on a data call can come from a proxy or rate limiter, and acting on it wipes the
    /// stored credentials. Only a failing session check proves the app password was revoked.
    private func sessionRevoked(_ creds: Credentials) async -> Bool {
        if case .unauthorized = await client.validateSession(creds) { return true }
        return false
    }

    func cachedFrames() -> [Frame] {
        guard let data = defaults.data(forKey: Keys.frames),
              let frames = try? JSONDecoder().decode([Frame].self, from: data)
        else { return [] }
        return frames
    }

    func refreshFrames() async -> RefreshOutcome {
        guard let creds = currentCredentials() else { return .sessionExpired }
        let event = Telemetry.Events.destinationsRefresh
        switch await client.listDestinations(creds) {
        case let .success(frames):
            persistFrames(frames)
            Telemetry.shared.event(event, ["outcome": "success", "count": frames.count])
            Telemetry.shared.setKey("destination_count", frames.count)
            return .success(frames)
        case .unauthorized:
            guard await sessionRevoked(creds) else { return .serverProblem(401) }
            logOut(wipeUploads: false)
            Telemetry.shared.event(event, ["outcome": "session_expired"])
            Telemetry.shared.event(Telemetry.Events.sessionRevoked, ["at": "refresh"])
            return .sessionExpired
        case .networkError:
            Telemetry.shared.event(event, ["outcome": "unreachable"])
            return .unreachable
        case let .serverError(code):
            Telemetry.shared.event(event, ["outcome": "server_error", "code": code])
            return .serverProblem(code)
        case let .malformed(detail):
            Telemetry.shared.event(event, ["outcome": "malformed"])
            Telemetry.shared.recordAPIDrift("discovery:/shares", detail)
            return .serverProblem(0)
        }
    }

    /// Feature-flagged gallery: list one frame folder's files.
    func listFolder(_ frame: Frame) async -> FolderOutcome {
        guard let creds = currentCredentials() else { return .sessionExpired }
        switch await client.listFolder(creds, remotePath: frame.remotePath) {
        case let .success(items):
            Telemetry.shared.event("gallery_open", ["count": items.count])
            return .success(items)
        case .unauthorized:
            guard await sessionRevoked(creds) else { return .serverProblem(401) }
            logOut(wipeUploads: false)
            return .sessionExpired
        case .networkError:
            return .unreachable
        case let .serverError(code):
            return .serverProblem(code)
        case let .malformed(detail):
            Telemetry.shared.recordAPIDrift("gallery:PROPFIND", detail)
            return .serverProblem(0)
        }
    }

    /// Feature-flagged, permission-gated: delete one file from a frame folder.
    func deleteItem(_ item: RemoteItem) async -> DeleteOutcome {
        guard let creds = currentCredentials() else { return .sessionExpired }
        let outcome: DeleteOutcome
        let label: String
        switch await client.deleteItem(creds, href: item.href) {
        case .success:
            (outcome, label) = (.success, "success")
        case .unauthorized:
            if await sessionRevoked(creds) {
                logOut(wipeUploads: false)
                (outcome, label) = (.sessionExpired, "session_expired")
            } else {
                (outcome, label) = (.serverProblem(401), "server_error")
            }
        case .forbidden:
            (outcome, label) = (.forbidden, "forbidden")
        case .destinationMissing:
            (outcome, label) = (.alreadyGone, "already_gone")
        case .conflict:
            (outcome, label) = (.serverProblem(409), "server_error")
        case .quotaExceeded:
            (outcome, label) = (.serverProblem(507), "server_error")
        case let .rejected(code), let .serverError(code):
            (outcome, label) = (.serverProblem(code), "server_error")
        case .network:
            (outcome, label) = (.unreachable, "unreachable")
        }
        Telemetry.shared.event("gallery_item_deleted", ["outcome": label])
        return outcome
    }

    /// Signs out and removes everything that outlives the session: the credential, cached
    /// lists, and (via `.mantelDidSignOut`) cached thumbnails and downloads — private family
    /// photos.
    ///
    /// `wipeUploads` also cancels queued/running uploads and deletes their staged copies. It
    /// is `true` for the user's own sign-out, and `false` when the server revoked the session:
    /// then the user's not-yet-sent photos are kept and resume after they sign back in.
    func logOut(wipeUploads: Bool = true) {
        let outgoing = credentials ?? store.load()
        store.clear()
        credentials = nil
        // The uid is kept after a revocation, so a different account signing in next can be
        // told apart from the same one returning.
        let keys = wipeUploads ? Keys.all : Keys.all.filter { $0 != Keys.userId }
        for key in keys { defaults.removeObject(forKey: key) }
        if wipeUploads { UploadCoordinator.shared.cancelAllAndWipe(credentials: outgoing) }
        PrivateImageCache.wipe()
        NotificationCenter.default.post(name: .mantelDidSignOut, object: nil)
    }

    private func persistFrames(_ frames: [Frame]) {
        guard let data = try? JSONEncoder().encode(frames) else { return }
        defaults.set(data, forKey: Keys.frames)
    }

    private enum Keys {
        static let frames = "frames_json"
        static let userId = "user_id"
        static let lastDestination = "last_destination_id"
        static var all: [String] { [frames, userId, lastDestination, "username"] }
    }
}
