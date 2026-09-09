import Foundation

/// User-facing copy for every network/auth outcome. Centralised so it maps 1:1
/// to the tables in Requirements §7 and API Contract §5.
enum Messages {
    static let sessionRevoked =
        "Your access was revoked or your password expired — please log in again."
    static let offlineCached =
        "No connection — showing the last known list. Tap Refresh when you're back online."
    static let serverCached =
        "Couldn't reach the server — showing the last known list."
    static let invalidCredentials =
        "That username or app password wasn't accepted. Remember to use an app password, "
            + "not your Nextcloud login password — ask your admin if you don't have one."
    static let noConnection =
        "No connection — check your network and try again."

    static func serverError(_ code: Int) -> String {
        code > 0
            ? "Server error (\(code)) — try again in a moment."
            : "The server sent something unexpected — try again in a moment."
    }

    /// Maps an upload error kind (see `UploadOutcome`) to user copy.
    static func uploadError(_ kind: String?) -> String {
        switch kind {
        case "auth": "Your access expired — sign in again, then resend."
        case "no_credentials": "You're signed out — sign in again, then resend."
        case "forbidden":
            "Couldn't upload — a file with this name may already exist on the frame, "
                + "or you don't have permission to add to it."
        case "dest_missing": "That frame is no longer shared with you."
        case "quota": "The server is out of storage space."
        case "network":
            "No connection — this one didn't finish. Try again when you're back online."
        case "server": "The server had a problem — this one didn't finish."
        case "unreadable_file": "Couldn't read that file from your phone."
        default: "This one didn't finish."
        }
    }
}
