import Foundation

/// Outcome of a read-only API call (session check, discovery, folder listing).
enum APIResult<T> {
    case success(T)
    case unauthorized // 401 — re-login, never retry
    case serverError(Int) // 5xx / unexpected status — retry with backoff
    case networkError(Error) // no response — retry with backoff
    /// Parseable transport, unparseable body (API shape drift). The detail is an
    /// `APIDiagnostics` description (shape only) — safe to send to diagnostics.
    case malformed(String)
}

/// Outcome of a WebDAV step (PUT / MKCOL / MOVE / DELETE), shaped to
/// Requirements §7 / API Contract §5.
enum WebDAVResult: Equatable {
    case success
    case unauthorized // 401 — re-login, never retry
    case forbidden // 403 — permission / name collision, never retry
    case destinationMissing // 404/409 — share revoked or parent gone
    case conflict // 412 — a file with this name already exists
    case quotaExceeded // 507 — server full, never retry
    case rejected(Int) // other 4xx — the request itself is wrong, never retry
    case serverError(Int) // 5xx / 408 / 423 / 429 — retry with backoff
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
///
/// Redirects are followed only when they stay on the original host over HTTPS, so
/// the preemptive `Authorization` header can never be replayed to another origin.
struct NextcloudClient {
    private let baseURL: URL
    private let api: URLSession
    private let transfer: URLSession

    /// Shared by every client: a `URLSession` retains its delegate until invalidated, so a
    /// session per client instance would leak. `RedirectGuard` is stateless, so sharing is safe.
    /// Short OCS / PROPFIND calls, with an overall deadline.
    private static let sharedAPI = makeSession(stallSeconds: 60, totalSeconds: 90)
    /// Control requests around uploads: `MOVE` returns only once the server has assembled
    /// every chunk, which can take minutes for a multi-GB file.
    private static let sharedTransfer = makeSession(stallSeconds: 600, totalSeconds: 1800)

    /// Every call goes to `baseURL`. Uploads pin it per batch so staging and the final
    /// `MOVE` stay on one server for the life of that upload.
    init(baseURL: URL = Config.baseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            api = session
            transfer = session
        } else {
            api = Self.sharedAPI
            transfer = Self.sharedTransfer
        }
    }

    private static func makeSession(stallSeconds: TimeInterval, totalSeconds: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = stallSeconds
        config.timeoutIntervalForResource = totalSeconds
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    // MARK: - Read-only OCS calls

    /// API Contract §1 — call on launch and before trusting cached state.
    func validateSession(_ creds: Credentials) async -> APIResult<UserInfo> {
        await getJSON("/ocs/v1.php/cloud/user?format=json", creds) { root in
            guard let ocs = root["ocs"] as? [String: Any],
                  let data = ocs["data"] as? [String: Any]
            else { throw ParseError() }
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
            else { throw ParseError() }

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
        let folder = folderURL(userId: creds.userId, remotePath: remotePath)
        var request = URLRequest(url: folder)
        request.httpMethod = "PROPFIND"
        request.setValue(creds.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)

        let started = Date()
        do {
            let (data, response) = try await api.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .malformed("no response") }
            crumb(request, status: http.statusCode, since: started)
            switch http.statusCode {
            case 401: return .unauthorized
            case 404: return .serverError(404)
            case 200, 207:
                do {
                    let encodedPath = URLComponents(url: folder, resolvingAgainstBaseURL: false)?
                        .percentEncodedPath ?? folder.path
                    let items = try PropfindParser(selfSegments: hrefSegments(encodedPath)).parse(data)
                    return .success(items)
                } catch let failure as PropfindParser.ParseFailure {
                    return .malformed(APIDiagnostics.describeXML(
                        status: http.statusCode,
                        contentType: http.value(forHTTPHeaderField: "Content-Type"),
                        line: failure.line,
                        column: failure.column
                    ))
                } catch {
                    return .malformed("xml: \(String(describing: type(of: error)))")
                }
            default: return .serverError(http.statusCode)
            }
        } catch {
            crumb(request, failure: error, since: started)
            return .networkError(error)
        }
    }

    /// True if `fileURL` already exists with exactly `sizeBytes` and modification time
    /// `mtimeSeconds` — i.e. an earlier attempt's upload succeeded but its response was
    /// lost. Needs Read on the share; any failure means "unknown".
    func remoteFileMatches(
        _ creds: Credentials,
        fileURL: URL,
        sizeBytes: Int64,
        mtimeSeconds: Int64
    ) async -> Bool {
        var request = URLRequest(url: fileURL)
        request.httpMethod = "PROPFIND"
        request.setValue(creds.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.propfindBody.utf8)
        guard let (data, response) = try? await api.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 207,
              let items = try? PropfindParser(selfSegments: nil).parse(data)
        else { return false }
        return items.contains {
            $0.sizeBytes == sizeBytes && Int64($0.lastModified.timeIntervalSince1970) == mtimeSeconds
        }
    }

    // MARK: - WebDAV control requests (small — safe on a foreground session)

    /// `MKCOL` a chunked-upload staging collection. `uploadID` is client-generated and
    /// must be stable across retries of the same file: if the collection already exists
    /// (405) this is a retry, and that counts as success.
    func makeCollection(_ creds: Credentials, uploadID: String) async -> WebDAVResult {
        await davRequest("MKCOL", url: stagingURL(userId: creds.userId, uploadID: uploadID), creds: creds) {
            $0 == 405 ? .success : nil
        }
    }

    /// `MOVE` the assembled `.file` onto its final destination (API Contract §4 step 3).
    /// Unless `overwrite`, the request carries `Overwrite: F` so an existing file yields
    /// `.conflict` instead of being silently replaced on shares that grant Update.
    func assembleChunks(
        _ creds: Credentials,
        uploadID: String,
        destinationURL: URL,
        totalBytes: Int64,
        mtime: Int64?,
        overwrite: Bool = false
    ) async -> WebDAVResult {
        let source = stagingURL(userId: creds.userId, uploadID: uploadID).appendingPathComponent(".file")
        var headers = [
            "Destination": destinationURL.absoluteString,
            "OC-Total-Length": String(totalBytes),
        ]
        if let mtime { headers["X-OC-Mtime"] = String(mtime) }
        if !overwrite { headers["Overwrite"] = "F" }
        return await davRequest("MOVE", url: source, creds: creds, headers: headers)
    }

    /// Best-effort removal of a staging collection once its upload has reached a final
    /// outcome (API Contract §4). An orphan is reported, never fatal.
    func discardStaging(_ creds: Credentials, uploadID: String) async {
        let result = await davRequest(
            "DELETE",
            url: stagingURL(userId: creds.userId, uploadID: uploadID),
            creds: creds
        )
        // 404 = never created or already assembled; anything else non-2xx may leave an orphan.
        if result != .success, result != .destinationMissing {
            Telemetry.shared.recordNonFatal(
                NSError(domain: "OrphanedStaging", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "orphaned upload staging: cleanup=\(result)",
                ]),
                context: "orphaned_upload_staging"
            )
        }
    }

    /// WebDAV `DELETE` of one file (gallery admin delete, API Contract §9).
    /// Requires the share's Delete bit; `403` if not granted.
    func deleteItem(_ creds: Credentials, href: String) async -> WebDAVResult {
        // Resolve against our own origin: a server-supplied href can never redirect the
        // (preemptive) Authorization header to another host.
        guard let url = URL(string: hrefPath(href), relativeTo: baseURL)?.absoluteURL else {
            return .rejected(0)
        }
        return await davRequest("DELETE", url: url, creds: creds)
    }

    // MARK: - URLs

    private func folderURL(userId: String, remotePath: String) -> URL {
        let folder = davFolderURL(baseURL: baseURL, userId: userId, remotePath: remotePath)
        return URL(string: folder.absoluteString.trimmingTrailingSlashes() + "/") ?? folder
    }

    private func stagingURL(userId: String, uploadID: String) -> URL {
        baseURL
            .appendingPathComponent("remote.php/dav/uploads")
            .appendingPathComponent(userId)
            .appendingPathComponent(uploadID)
    }

    // MARK: - Plumbing

    /// `interpret` lets a caller reinterpret one status code (e.g. `405` on `MKCOL`).
    private func davRequest(
        _ method: String,
        url: URL,
        creds: Credentials,
        headers: [String: String] = [:],
        interpret: ((Int) -> WebDAVResult?)? = nil
    ) async -> WebDAVResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(creds.basicAuthHeader, forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let started = Date()
        do {
            let (_, response) = try await transfer.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .network }
            crumb(request, status: http.statusCode, since: started)
            return interpret?(http.statusCode) ?? Self.classify(http.statusCode)
        } catch {
            crumb(request, failure: error, since: started)
            return .network
        }
    }

    static func classify(_ status: Int) -> WebDAVResult {
        switch status {
        case 200, 201, 204: .success
        case 401: .unauthorized
        case 403: .forbidden
        case 404, 409: .destinationMissing
        case 412: .conflict
        case 507: .quotaExceeded
        case 408, 423, 429, 500 ... 599: .serverError(status)
        default: .rejected(status)
        }
    }

    private func getJSON<T>(
        _ path: String,
        _ creds: Credentials,
        parse: @escaping ([String: Any]) throws -> T
    ) async -> APIResult<T> {
        guard let url = URL(string: baseURL.absoluteString.trimmingTrailingSlashes() + path) else {
            return .malformed("bad request url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(creds.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let started = Date()
        do {
            let (data, response) = try await api.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .malformed("no response") }
            crumb(request, status: http.statusCode, since: started)
            if http.statusCode == 401 { return .unauthorized }
            guard (200 ... 299).contains(http.statusCode) else { return .serverError(http.statusCode) }
            do {
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                return try .success(parse(root))
            } catch {
                return .malformed(APIDiagnostics.describe(
                    status: http.statusCode,
                    contentType: http.value(forHTTPHeaderField: "Content-Type"),
                    body: data,
                    failure: error
                ))
            }
        } catch {
            crumb(request, failure: error, since: started)
            return .networkError(error)
        }
    }

    private struct ParseError: Error {}

    // MARK: - Breadcrumbs

    /// Leaves a `METHOD route -> status (ms)` breadcrumb per request so a diagnostic
    /// shows the last network activity. Routes are a fixed vocabulary — never a path,
    /// user or file name — and thumbnail fetches don't come through here.
    private func crumb(_ request: URLRequest, status: Int, since started: Date) {
        guard let route = Self.route(of: request.url?.path ?? "") else { return }
        Telemetry.shared.breadcrumb(
            "\(request.httpMethod ?? "GET") \(route) -> \(status) (\(Self.elapsedMs(since: started))ms)"
        )
    }

    private func crumb(_ request: URLRequest, failure: Error, since started: Date) {
        guard let route = Self.route(of: request.url?.path ?? "") else { return }
        let kind = (failure as? URLError).map { "URLError.\($0.code.rawValue)" }
            ?? String(describing: type(of: failure))
        Telemetry.shared.breadcrumb(
            "\(request.httpMethod ?? "GET") \(route) -> \(kind) (\(Self.elapsedMs(since: started))ms)"
        )
    }

    private static func elapsedMs(since started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }

    private static func route(of path: String) -> String? {
        if path.contains("/cloud/user") { return "ocs/user" }
        if path.contains("/files_sharing/") { return "ocs/shares" }
        if path.contains("/dav/uploads/") { return path.hasSuffix("/.file") ? "dav/assemble" : "dav/staging" }
        if path.contains("/dav/files/") { return "dav/files" }
        return nil
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
        <nc:upload_time/>
      </d:prop>
    </d:propfind>
    """
}

/// Follows a redirect only if it stays on the original host over HTTPS.
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.allows(request, for: task) ? request : nil)
    }

    static func allows(_ request: URLRequest, for task: URLSessionTask) -> Bool {
        request.url?.scheme == "https" && request.url?.host == task.originalRequest?.url?.host
    }
}

private func intValue(_ any: Any?) -> Int? {
    switch any {
    case let value as Int: value
    case let value as String: Int(value)
    case let value as NSNumber: value.intValue
    default: nil
    }
}
