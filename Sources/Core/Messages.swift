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
    static let nothingStaged =
        "Couldn't prepare those files — they may be too large, unreadable, or your phone is out of space."
    static let storageFailed =
        "Signed in, but this device wouldn't keep your sign-in safely. Try again — if it keeps "
            + "happening, restart your phone."
    static let noConnection =
        "No connection — check your network and try again."

    static func serverError(_ code: Int) -> String {
        code > 0
            ? "Server error (\(code)) — try again in a moment."
            : "The server sent something unexpected — try again in a moment."
    }

    /// Why nothing (or, for a single pick, that item) could be staged.
    static func stagingFailure(_ reason: StagingFailure.Reason?) -> String {
        switch reason {
        case .tooLarge: "That file is too large to send (the limit is 4 GB)."
        case .noSpace: "Your phone is out of space, so those files couldn't be prepared."
        case .unreadable, nil: nothingStaged
        }
    }

    /// Shown on the upload status screen when some picks couldn't be staged.
    static func skippedFiles(_ count: Int) -> String {
        "\(count) \(count == 1 ? "file" : "files") couldn't be prepared "
            + "(too large, unreadable, or your phone is out of space) and won't be sent."
    }

    /// Maps an upload failure to user copy.
    static func uploadError(_ error: UploadError?) -> String {
        switch error {
        case .auth: "Your access expired — sign in again, then resend."
        case .noCredentials: "You're signed out — sign in again, then resend."
        case .forbidden:
            "Couldn't upload — you may not have permission to add to this frame, "
                + "or a file with this name already exists there."
        case .conflict: "A file with this name already exists on the frame."
        case .destMissing: "That frame is no longer shared with you."
        case .quota: "The server is out of storage space."
        case .network: "No connection — this one didn't finish. Try again when you're back online."
        case .server: "The server had a problem — this one didn't finish."
        case .rejected: "The server refused this file."
        case .unreadableFile: "Couldn't read that file from your phone."
        case .badInput, nil: "This one didn't finish."
        }
    }
}
