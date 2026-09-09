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

    var username: String? {
        credentials?.username ?? defaults.string(forKey: Keys.username)
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
        switch await client.validateSession(stored) {
        case .success:
            defaults.set(stored.username, forKey: Keys.username)
            return .ready(offlineNotice: nil)
        case .unauthorized:
            logOut()
            Telemetry.shared.event(Telemetry.Events.sessionRevoked, ["at": "launch"])
            return .revoked(Messages.sessionRevoked)
        case .networkError:
            return .ready(offlineNotice: Messages.offlineCached)
        case .serverError:
            return .ready(offlineNotice: Messages.serverCached)
        case let .malformed(detail):
            reportAPIDrift("bootstrap:/cloud/user", detail)
            return .ready(offlineNotice: Messages.serverCached)
        }
    }

    func logIn(username: String, appPassword: String) async -> LoginOutcome {
        let creds = Credentials(
            username: username.trimmingCharacters(in: .whitespaces),
            appPassword: appPassword
        )
        switch await client.validateSession(creds) {
        case let .success(user):
            store.save(creds)
            credentials = creds
            defaults.set(creds.username, forKey: Keys.username)
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
            reportAPIDrift("login:/cloud/user", detail)
            return .serverProblem(0)
        }
    }

    func cachedFrames() -> [Frame] {
        guard let data = defaults.data(forKey: Keys.frames),
              let frames = try? JSONDecoder().decode([Frame].self, from: data)
        else { return [] }
        return frames
    }

    func refreshFrames() async -> RefreshOutcome {
        guard let creds = currentCredentials() else { return .sessionExpired }
        switch await client.listDestinations(creds) {
        case let .success(frames):
            persistFrames(frames)
            Telemetry.shared.event(
                Telemetry.Events.framesRefresh,
                ["outcome": "success", "count": frames.count]
            )
            Telemetry.shared.setKey("frame_count", frames.count)
            return .success(frames)
        case .unauthorized:
            logOut()
            Telemetry.shared.event(Telemetry.Events.framesRefresh, ["outcome": "session_expired"])
            Telemetry.shared.event(Telemetry.Events.sessionRevoked, ["at": "refresh"])
            return .sessionExpired
        case .networkError:
            Telemetry.shared.event(Telemetry.Events.framesRefresh, ["outcome": "unreachable"])
            return .unreachable
        case let .serverError(code):
            Telemetry.shared.event(
                Telemetry.Events.framesRefresh,
                ["outcome": "server_error", "code": code]
            )
            return .serverProblem(code)
        case let .malformed(detail):
            Telemetry.shared.event(Telemetry.Events.framesRefresh, ["outcome": "malformed"])
            reportAPIDrift("discovery:/shares", detail)
            return .serverProblem(0)
        }
    }

    /// Feature-flagged gallery: list one frame folder's files.
    func listFolder(_ frame: Frame) async -> FolderOutcome {
        guard let creds = currentCredentials() else { return .sessionExpired }
        switch await client.listFolder(creds, remotePath: frame.remotePath) {
        case let .success(items):
            Telemetry.shared.event("frame_gallery_open", ["count": items.count])
            return .success(items)
        case .unauthorized:
            logOut()
            return .sessionExpired
        case .networkError:
            return .unreachable
        case let .serverError(code):
            return .serverProblem(code)
        case let .malformed(detail):
            reportAPIDrift("gallery:PROPFIND", detail)
            return .serverProblem(0)
        }
    }

    /// Feature-flagged, permission-gated: delete one file from a frame folder.
    func deleteItem(_ item: RemoteItem) async -> DeleteOutcome {
        guard let creds = currentCredentials() else { return .sessionExpired }
        let outcome: DeleteOutcome
        switch await client.deleteItem(creds, href: item.href) {
        case .success: outcome = .success
        case .unauthorized:
            logOut()
            outcome = .sessionExpired
        case .forbidden: outcome = .forbidden
        case .destinationMissing: outcome = .alreadyGone
        case .quotaExceeded: outcome = .serverProblem(507)
        case let .serverError(code): outcome = .serverProblem(code)
        case .network: outcome = .unreachable
        }
        Telemetry.shared.event("frame_item_deleted", ["outcome": String(describing: outcome)])
        return outcome
    }

    func logOut() {
        store.clear()
        credentials = nil
        for key in Keys.all { defaults.removeObject(forKey: key) }
    }

    /// A parseable-but-unexpected server response (JSON/XML shape drift), surfaced
    /// as a non-fatal so API changes show up in diagnostics rather than silently
    /// degrading to "server error". Carries no response body.
    private func reportAPIDrift(_ location: String, _ detail: String) {
        Telemetry.shared.recordNonFatal(
            NSError(domain: "APIDrift", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "\(location): \(detail)"]),
            context: "api_drift"
        )
    }

    private func persistFrames(_ frames: [Frame]) {
        guard let data = try? JSONEncoder().encode(frames) else { return }
        defaults.set(data, forKey: Keys.frames)
    }

    private enum Keys {
        static let frames = "frames_json"
        static let username = "username"
        static let lastDestination = "last_destination_id"
        static var all: [String] { [frames, username, lastDestination] }
    }
}
