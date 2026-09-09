import SwiftUI
import UIKit

/// Loads a private Nextcloud image (preview thumbnail or full download) with the
/// app-password Basic-auth header — but only for requests to `Config.host`
/// (Requirements §13.1; mirrors the Android `FrameImageLoader`).
///
/// First-party only: a plain `URLSession` plus an `NSCache`. No image library.
@MainActor
final class AuthedImageLoader {
    static let shared = AuthedImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config)
    }()

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL, credentials: Credentials?) async -> UIImage? {
        if let hit = cached(url) { return hit }
        var request = URLRequest(url: url)
        if let credentials, url.host == Config.host {
            request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
              let image = UIImage(data: data)
        else { return nil }
        cache.setObject(image, forKey: url as NSURL)
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
            let loaded = await AuthedImageLoader.shared.load(url, credentials: credentials)
            if let loaded {
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
