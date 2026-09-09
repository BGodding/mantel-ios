import Foundation

/// Nextcloud username + app password. Never the primary login password (Requirements §4).
struct Credentials: Equatable {
    let username: String
    let appPassword: String

    /// `Basic base64(username:appPassword)` — the only form the credential ever
    /// leaves the device in, and only to `Config.host` over TLS.
    var basicAuthHeader: String {
        let raw = Data("\(username):\(appPassword)".utf8)
        return "Basic " + raw.base64EncodedString()
    }
}

// periphery:ignore - typed result of the session check; parity with Android, surfaced in a later account view
/// Identity returned by `GET /ocs/v1.php/cloud/user`.
struct UserInfo: Equatable {
    let id: String
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
    func uploadCollectionURL(username: String) -> URL {
        var url = Config.baseURL
            .appendingPathComponent("remote.php/dav/files")
            .appendingPathComponent(username)
        for segment in remotePath.split(separator: "/") where !segment.isEmpty {
            url.appendPathComponent(String(segment))
        }
        return url
    }
}

/// One file inside a frame folder, from a WebDAV `PROPFIND` (used by the gallery feature).
struct RemoteItem: Identifiable, Equatable {
    /// Server-absolute, percent-encoded path, e.g. `/remote.php/dav/files/bob/Grandma/IMG_1.jpg`.
    let href: String
    let name: String
    // periphery:ignore - always false after parsing (collections are dropped); kept so the model matches PROPFIND
    let isDirectory: Bool
    let contentType: String
    // periphery:ignore - parsed from getcontentlength; not surfaced in the gallery yet
    let sizeBytes: Int64
    let lastModified: Date
    /// Nextcloud numeric file id, for the preview endpoint.
    let fileID: String?
    let hasPreview: Bool

    var id: String { href }
    var isVideo: Bool { contentType.hasPrefix("video/") }

    var downloadURL: URL {
        URL(string: Config.baseURL.absoluteString + href) ?? Config.baseURL
    }

    /// Nextcloud preview endpoint; nil when the server reported no preview / no id.
    func previewURL(px: Int = 300) -> URL? {
        guard hasPreview, let fileID else { return nil }
        return URL(string:
            "\(Config.baseURL.absoluteString)/index.php/core/preview?fileId=\(fileID)&x=\(px)&y=\(px)&a=1")
    }
}

/// Percent-encodes a single path segment the way Nextcloud expects (space as `%20`,
/// not `+`; `/` encoded so it can never split the path).
func pathSegmentEncoded(_ segment: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
}
