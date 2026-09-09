import Foundation

/// Outcome of a read-only API call (session check, discovery, folder listing).
enum APIResult<T> {
    case success(T)
    case unauthorized // 401 — re-login, never retry
    case serverError(Int) // 5xx / unexpected status — retry with backoff
    case networkError(Error) // no response — retry with backoff
    case malformed(String) // parseable transport, unparseable body (API shape drift)
}

/// Outcome of a WebDAV mutation step (PUT / MKCOL / MOVE / DELETE), shaped to
/// Requirements §7 / API Contract §5.
enum WebDAVResult: Equatable {
    case success
    case unauthorized // 401
    case forbidden // 403 — permission / name collision, never retry
    case destinationMissing // 404 — share revoked since last refresh
    case quotaExceeded // 507
    case serverError(Int) // 5xx / other
    case network // no response — retry with backoff
}

/// Thin Nextcloud client over `URLSession`.
///
/// Only first-party APIs — `URLSession` speaks the WebDAV verbs (`MKCOL`, `MOVE`,
/// `PROPFIND`, `DELETE`) directly via `httpMethod`, and `XMLParser` handles the
/// `PROPFIND` multistatus body. Large byte transfers do **not** go through here —
/// they run as background `URLSession` upload tasks in `UploadCoordinator` so they
/// survive suspension. This client carries the read calls and the small control
/// requests (`MKCOL`, `MOVE`, `DELETE`).
struct NextcloudClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            config.waitsForConnectivity = false
            config.tlsMinimumSupportedProtocolVersion = .TLSv12
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Read-only OCS calls

    /// API Contract §1 — call on launch and before trusting cached state.
    func validateSession(_ creds: Credentials) async -> APIResult<UserInfo> {
        await getJSON("/ocs/v1.php/cloud/user?format=json", creds) { root in
            guard let ocs = root["ocs"] as? [String: Any],
                  let data = ocs["data"] as? [String: Any]
            else { throw ParseError("missing ocs.data") }
            let id = (data["id"] as? String) ?? ""
            let name = (data["displayname"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return UserInfo(id: id, displayName: name)
        }
    }

    /// API Contract §2 — the live "what can I upload to right now" call.
    func listDestinations(_ creds: Credentials) async -> APIResult<[Frame]> {
        await getJSON(
            "/ocs/v2.php/apps/files_sharing/api/v1/shares?shared_with_me=true&format=json",
            creds
        ) { root in
            guard let ocs = root["ocs"] as? [String: Any],
                  let shares = ocs["data"] as? [[String: Any]]
            else { throw ParseError("missing ocs.data array") }

            return shares.compactMap { share -> Frame? in
                let isFolder = (share["item_type"] as? String) == "folder"
                let permissions = intValue(share["permissions"]) ?? 0
                let rawTarget = (share["file_target"] as? String)
                    ?? (share["path"] as? String) ?? ""
                let target = rawTarget.trimmingCharacters(in: .whitespaces)
                guard isFolder, permissions & Permission.create != 0, !target.isEmpty
                else { return nil }

                let normalised = "/" + target.split(separator: "/").joined(separator: "/")
                let label = String(normalised.drop(while: { $0 == "/" }))
                return Frame(
                    id: (share["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? normalised,
                    displayName: label.isEmpty ? normalised : label,
                    remotePath: normalised,
                    permissions: permissions
                )
            }
        }
    }

    // MARK: - Frame gallery (feature-flagged)

    /// WebDAV `PROPFIND` (`Depth: 1`) listing of one frame folder's files.
    /// NOT covered by the validated API surface — verify the response shape against
    /// the live server before relying on this in production (API Contract §7).
    func listFolder(_ creds: Credentials, remotePath: String) async -> APIResult<[RemoteItem]> {
        let davPath = davFolder(creds.username, remotePath)
        guard let url = URL(string: Config.baseURL.absoluteString + davPath) else {
            return .malformed("bad folder path")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue(creds.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .malformed("no response") }
            switch http.statusCode {
            case 401: return .unauthorized
            case 404: return .serverError(404)
            case 200, 207:
                let items = PropfindParser(selfPath: davPath).parse(data)
                return .success(items)
            case 500 ... 599: return .serverError(http.statusCode)
            default: return .serverError(http.statusCode)
            }
        } catch {
            return .networkError(error)
        }
    }

    // MARK: - WebDAV control requests (small — safe on a foreground session)

    /// `MKCOL` a chunked-upload staging collection. `uploadID` is client-generated.
    func makeCollection(_ creds: Credentials, uploadID: String) async -> WebDAVResult {
        let url = Config.baseURL
            .appendingPathComponent("remote.php/dav/uploads")
            .appendingPathComponent(creds.username)
            .appendingPathComponent(uploadID)
        return await davRequest("MKCOL", url: url, creds: creds)
    }

    /// `MOVE` the assembled `.file` onto its final destination (API Contract §4 step 3).
    func assembleChunks(
        _ creds: Credentials,
        uploadID: String,
        destinationURL: URL,
        totalBytes: Int64,
        mtime: Int64?
    ) async -> WebDAVResult {
        let source = Config.baseURL
            .appendingPathComponent("remote.php/dav/uploads")
            .appendingPathComponent(creds.username)
            .appendingPathComponent(uploadID)
            .appendingPathComponent(".file")
        var headers = ["Destination": destinationURL.absoluteString,
                       "OC-Total-Length": String(totalBytes)]
        if let mtime { headers["X-OC-Mtime"] = String(mtime) }
        return await davRequest("MOVE", url: source, creds: creds, headers: headers)
    }

    /// Best-effort cleanup of an abandoned staging collection (API Contract §4).
    @discardableResult
    func deleteCollection(_ creds: Credentials, uploadID: String) async -> WebDAVResult {
        let url = Config.baseURL
            .appendingPathComponent("remote.php/dav/uploads")
            .appendingPathComponent(creds.username)
            .appendingPathComponent(uploadID)
        return await davRequest("DELETE", url: url, creds: creds)
    }

    /// WebDAV `DELETE` of one file (gallery admin delete, API Contract §9).
    /// Requires the share's Delete bit; `403` if not granted.
    func deleteItem(_ creds: Credentials, href: String) async -> WebDAVResult {
        guard let url = URL(string: Config.baseURL.absoluteString + href) else {
            return .serverError(0)
        }
        return await davRequest("DELETE", url: url, creds: creds)
    }

    // MARK: - Plumbing

    private func davRequest(
        _ method: String,
        url: URL,
        creds: Credentials,
        headers: [String: String] = [:]
    ) async -> WebDAVResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(creds.basicAuthHeader, forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .network }
            return Self.classify(http.statusCode)
        } catch {
            return .network
        }
    }

    static func classify(_ status: Int) -> WebDAVResult {
        switch status {
        case 200, 201, 204: .success
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .destinationMissing
        case 507: .quotaExceeded
        default: .serverError(status)
        }
    }

    private func getJSON<T>(
        _ path: String,
        _ creds: Credentials,
        parse: @escaping ([String: Any]) throws -> T
    ) async -> APIResult<T> {
        guard let url = URL(string: Config.baseURL.absoluteString + path) else {
            return .malformed("bad url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(creds.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .malformed("no response") }
            if http.statusCode == 401 { return .unauthorized }
            guard (200 ... 299).contains(http.statusCode) else {
                return .serverError(http.statusCode)
            }
            do {
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                return try .success(parse(root))
            } catch {
                return .malformed(error.localizedDescription)
            }
        } catch {
            return .networkError(error)
        }
    }

    private func davFolder(_ username: String, _ remotePath: String) -> String {
        let segments = remotePath.split(separator: "/").filter { !$0.isEmpty }
            .map { pathSegmentEncoded(String($0)) }
        return "/remote.php/dav/files/\(pathSegmentEncoded(username))/"
            + segments.joined(separator: "/") + "/"
    }

    private struct ParseError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
      <d:prop>
        <d:resourcetype/>
        <d:getcontenttype/>
        <d:getcontentlength/>
        <d:getlastmodified/>
        <oc:fileid/>
        <nc:has-preview/>
      </d:prop>
    </d:propfind>
    """
}

private func intValue(_ any: Any?) -> Int? {
    switch any {
    case let value as Int: value
    case let value as String: Int(value)
    case let value as NSNumber: value.intValue
    default: nil
    }
}
