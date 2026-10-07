import SwiftUI
import UIKit

/// Loads a private Nextcloud image (preview thumbnail or full download) with the
/// app-password Basic-auth header — but only for requests to `Config.host`
/// (Requirements §13.1; mirrors the Android `NextcloudHttpClient`).
///
/// First-party only: a plain `URLSession` plus an `NSCache`. No image library.
///
/// Built so a gallery of several hundred photos loads quickly:
/// - many requests in flight per host (HTTP/2 multiplexes them over one connection),
///   matching the Nextcloud web UI, so the server is never left idle;
/// - a short timeout on thumbnails, so one preview the server can't generate can't hold a
///   slot and stall the grid;
/// - decoding happens off the main thread.
///
/// Everything it caches is a private family photo, so `.mantelDidSignOut` empties it.
final class AuthedImageLoader: @unchecked Sendable {
    static let shared = AuthedImageLoader()

    private static let previewPathSuffix = "/core/preview"
    private static let previewTimeout: TimeInterval = 20
    private static let maxRequestsPerHost = 24

    /// Decoded bitmaps are large (a 12 MP photo is ~48 MB), so bound the cache by bytes.
    private static let cacheByteLimit = 128 * 1024 * 1024

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.httpMaximumConnectionsPerHost = Self.maxRequestsPerHost
        config.urlCache = PrivateImageCache.urlCache
        cache.totalCostLimit = Self.cacheByteLimit
        session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)

        NotificationCenter.default.addObserver(
            forName: .mantelDidSignOut, object: nil, queue: nil
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    /// Drops every cached image and response.
    func removeAll() {
        cache.removeAllObjects()
        PrivateImageCache.wipe()
    }

    func load(_ url: URL, credentials: Credentials?) async -> UIImage? {
        if let hit = cached(url) { return hit }
        var request = URLRequest(url: url)
        if url.path.hasSuffix(Self.previewPathSuffix) { request.timeoutInterval = Self.previewTimeout }
        if let credentials, url.scheme == "https", url.host == Config.host {
            request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
              let decoded = UIImage(data: data)
        else { return nil }
        let image = decoded.preparingForDisplay() ?? decoded
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }
}

/// Drop-in async image view with a loading spinner and a "preview pending"
/// placeholder for the lazy-thumbnail case (Requirements §13.1).
struct AuthedAsyncImage<Placeholder: View>: View {
    let url: URL?
    let credentials: Credentials?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                placeholder()
            } else {
                ZStack {
                    Color(.secondarySystemBackground)
                    ProgressView()
                }
            }
        }
        .task(id: url) {
            image = nil
            failed = false
            guard let url else { failed = true; return }
            if let hit = AuthedImageLoader.shared.cached(url) {
                image = hit
                return
            }
            if let loaded = await AuthedImageLoader.shared.load(url, credentials: credentials) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

extension AuthedAsyncImage where Placeholder == PreviewPendingTile {
    init(url: URL?, credentials: Credentials?, contentMode: ContentMode = .fill) {
        self.init(url: url, credentials: credentials, contentMode: contentMode) {
            PreviewPendingTile()
        }
    }
}

/// Framed-square placeholder — reads as "preview pending", not "broken image".
struct PreviewPendingTile: View {
    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
                .frame(width: 28, height: 28)
        }
    }
}
