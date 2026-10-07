import Foundation

/// Nextcloud login name + app password. Never the primary login password (Requirements §4).
///
/// `username` is what the user typed and is used for Basic auth; `userId` is the server's
/// canonical uid (from `/cloud/user`), which is what the WebDAV paths are keyed by — the two
/// differ when someone logs in with an email address.
struct Credentials: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let username: String
    let appPassword: String
    let userId: String

    init(username: String, appPassword: String, userId: String? = nil) {
        self.username = username
        self.appPassword = appPassword
        self.userId = userId ?? username
    }

    /// `Basic base64(username:appPassword)` — the only form the credential ever
    /// leaves the device in, and only to `Config.host` over TLS.
    var basicAuthHeader: String {
        let raw = Data("\(username):\(appPassword)".utf8)
        return "Basic " + raw.base64EncodedString()
    }

    /// Keeps the secret out of logs, string interpolation and error messages.
    var description: String { "Credentials(userId=\(userId), appPassword=***)" }
    var debugDescription: String { description }
}

/// Identity returned by `GET /ocs/v1.php/cloud/user`. `id` is the canonical uid the
/// WebDAV paths are keyed by; `displayName` is not shown in the UI yet.
struct UserInfo: Equatable {
    let id: String
    // periphery:ignore - typed result of the session check; parity with Android, surfaced in a later account view
    let displayName: String
}

/// Nextcloud permission bits the client acts on (API Contract §2 lists the full
/// bitmask: Read=1, Update=2, Create=4, Delete=8, Share=16).
enum Permission {
    static let create = 4
    static let delete = 8
}

/// An upload destination discovered from the server's share graph (Requirements §5).
/// There is no client-side create/edit/remove — the server is the only source of truth.
struct Frame: Identifiable, Equatable, Codable {
    let id: String
    /// Human label, e.g. "Grandma" — derived from `remotePath`.
    let displayName: String
    /// Share target path, always leading-slash normalised, e.g. "/Grandma".
    let remotePath: String
    /// Nextcloud permission bitmask (Read=1, Update=2, Create=4, Delete=8, Share=16).
    let permissions: Int

    /// True when this share grants Create — i.e. it is a usable upload destination
    /// (every `Frame` in the discovery list already satisfies this; exposed for
    /// tests and callers that hold a `Frame` from elsewhere).
    var canUpload: Bool { permissions & Permission.create != 0 }

    /// True when this share grants Delete — i.e. the user is a "frame admin" for it.
    var canDelete: Bool { permissions & Permission.delete != 0 }

    /// WebDAV collection URL that files are `PUT` into, per API Contract §2/§3.
    func uploadCollectionURL(baseURL: URL = Config.baseURL, userId: String) -> URL {
        davFolderURL(baseURL: baseURL, userId: userId, remotePath: remotePath)
    }
}

/// `<base>/remote.php/dav/files/<userId>/<remotePath>` — every segment percent-encoded
/// as a path segment (`+` stays literal, spaces become `%20`).
func davFolderURL(baseURL: URL = Config.baseURL, userId: String, remotePath: String) -> URL {
    var url = baseURL
        .appendingPathComponent("remote.php/dav/files")
        .appendingPathComponent(userId)
    for segment in remotePath.split(separator: "/") where !segment.isEmpty {
        url.appendPathComponent(String(segment))
    }
    return url
}

/// One file inside a frame folder, from a WebDAV `PROPFIND` (used by the gallery feature).
struct RemoteItem: Identifiable, Equatable {
    /// Server-relative, percent-encoded path, e.g. `/remote.php/dav/files/bob/Grandma/IMG_1.jpg`.
    let href: String
    let name: String
    // periphery:ignore - always false after parsing (collections are dropped); kept so the model matches PROPFIND
    let isDirectory: Bool
    let contentType: String
    let sizeBytes: Int64
    let lastModified: Date
    /// Nextcloud numeric file id, for the preview endpoint.
    let fileID: String?
    let hasPreview: Bool
    /// Server-side upload time (`nc:upload_time`); nil when the server doesn't report it.
    let uploadedAt: Date?

    var id: String { href }
    var isImage: Bool { contentType.hasPrefix("image/") }
    var isVideo: Bool { contentType.hasPrefix("video/") }

    /// When the file reached the server, falling back to its modified time.
    var addedAt: Date { uploadedAt ?? lastModified }

    /// Resolved against our own origin, so a server-supplied href can never point the
    /// (preemptive) Authorization header at another host.
    var downloadURL: URL {
        URL(string: hrefPath(href), relativeTo: Config.baseURL)?.absoluteURL ?? Config.baseURL
    }

    /// Nextcloud preview endpoint; nil when the server reported no preview / no id.
    func previewURL(px: Int = 256) -> URL? {
        guard hasPreview, let fileID else { return nil }
        let base = Config.baseURL.absoluteString.trimmingTrailingSlashes()
        return URL(string: "\(base)/core/preview?fileId=\(fileID)&x=\(px)&y=\(px)&mimeFallback=true&a=0")
    }
}

// MARK: - Server-supplied hrefs

/// Host-less resolver for server-supplied hrefs (which may be a path or an absolute URL).
private let hrefResolver = URL(string: "https://href.invalid")!

/// Server-relative encoded path of `href`, dropping any scheme/host a server may have included.
func hrefPath(_ href: String) -> String {
    guard let url = URL(string: href, relativeTo: hrefResolver)?.absoluteURL,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return href }
    return components.percentEncodedPath
}

/// Decoded, non-empty path segments of a server-supplied `href`.
func hrefSegments(_ href: String) -> [String] {
    hrefPath(href)
        .split(separator: "/")
        .map { String($0).removingPercentEncoding ?? String($0) }
        .filter { !$0.isEmpty }
}
