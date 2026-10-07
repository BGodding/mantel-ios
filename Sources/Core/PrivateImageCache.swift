import Foundation

/// The on-disk cache behind `AuthedImageLoader` — private family photos and thumbnails.
///
/// It lives in Core (not next to the loader) so sign-out can empty it directly. Relying on
/// the loader to observe `.mantelDidSignOut` was not enough: the loader only exists once a
/// gallery has been opened, so a sign-out before that left the previous launch's files on
/// disk, readable by whoever signed in next. The directory is fixed and dedicated to this
/// cache, so `wipe()` reaches those files even in a process that never loaded an image.
enum PrivateImageCache {
    static let urlCache = URLCache(
        memoryCapacity: 32 * 1024 * 1024,
        diskCapacity: 256 * 1024 * 1024,
        directory: FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrivateImages", isDirectory: true)
    )

    static func wipe() {
        urlCache.removeAllCachedResponses()
    }
}
