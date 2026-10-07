import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Picker / share-sheet items arrive as `NSItemProvider`s whose backing file is
/// only guaranteed for the lifetime of the current callback. Deferred background
/// uploads (offline, app killed) can run much later, so every selection is copied
/// into the shared App Group container up front and the uploader is handed a
/// plain file URL it can always read.
///
/// Capture date is read from the file's own metadata (EXIF `DateTimeOriginal`
/// for images, `AVAsset` creation date for video) — no photo-library permission,
/// keeping the privacy posture of `PHPickerViewController` intact (Requirements
/// §6 / Goal 4).
/// `NSItemProvider`'s loading API and metadata accessors are documented as
/// thread-safe, but the type is not yet `Sendable`-annotated by Apple. This box
/// carries one across the actor hop into `MediaStaging.stage` without tripping
/// strict-concurrency diagnostics.
struct SendableItemProvider: @unchecked Sendable {
    let provider: NSItemProvider
}

/// Why a pick couldn't be staged. A fixed vocabulary, safe for telemetry.
struct StagingFailure: Error {
    enum Reason: String {
        case tooLarge = "too_large"
        case noSpace = "no_space"
        case unreadable
    }

    let reason: Reason
}

enum MediaStaging {
    /// Headroom kept free on the volume beyond the file being copied.
    private static let freeSpaceMargin: Int64 = 64 * 1024 * 1024

    /// Copies one item provider's file into `uploads/<batchID>/` and returns its
    /// metadata. Async because `loadFileRepresentation` is.
    ///
    /// The provider's file is only valid inside its callback, so it is copied straight to
    /// its final staged location there — one copy, not a temp copy followed by another.
    static func stage(_ item: SendableItemProvider, batchID: String) async throws -> StagedFile {
        let suggestedName = item.provider.suggestedName
        let staged = try await withLoadedFile(from: item.provider) { url -> (URL, String) in
            let size = fileSize(url)
            guard size <= UploadTuning.maxFileBytes else { throw StagingFailure(reason: .tooLarge) }
            guard hasSpace(for: size) else { throw StagingFailure(reason: .noSpace) }

            let ext = url.pathExtension
            let named = suggestedName.map { ext.isEmpty || $0.hasSuffix(".\(ext)") ? $0 : "\($0).\(ext)" }
            let displayName = RemoteNames.safe(named ?? url.lastPathComponent)
            let directory = SharedContainer.batchDir(batchID)
            let destination = directory.appendingPathComponent(
                RemoteNames.localFileName(displayName, in: directory)
            )
            do {
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw StagingFailure(reason: hasSpace(for: 0) ? .unreadable : .noSpace)
            }
            return (destination, displayName)
        }
        let (destination, displayName) = staged

        // The copied file's length is the truth; a wrong advertised size makes every
        // upload attempt fail.
        let actualSize = fileSize(destination)
        let mime = mimeType(for: destination, fallbackName: displayName)
        let capture = await captureDate(for: destination, mime: mime)

        return StagedFile(
            path: destination.path,
            displayName: displayName,
            mimeType: mime,
            sizeBytes: actualSize,
            captureEpochSeconds: capture.map { Int64($0.timeIntervalSince1970) }
        )
    }

    /// Drops stale staging directories that no live upload needs.
    static func sweepStale(activeBatchIDs: Set<String>) {
        SharedContainer.sweepStale(activeBatchIDs: activeBatchIDs)
    }

    // MARK: - Loading

    /// Runs `body` on the provider's file *inside* the load callback (the URL is valid only
    /// until the callback returns) and hands back whatever it produced.
    private static func withLoadedFile<T: Sendable>(
        from provider: NSItemProvider,
        _ body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        let type = preferredType(for: provider)
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url, error == nil else {
                    continuation.resume(throwing: StagingFailure(reason: .unreadable))
                    return
                }
                do {
                    try continuation.resume(returning: body(url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func preferredType(for provider: NSItemProvider) -> String {
        let match = [UTType.image, UTType.movie, UTType.video, UTType.data]
            .first { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        return match?.identifier
            ?? provider.registeredTypeIdentifiers.first
            ?? UTType.data.identifier
    }

    /// Whether `needed` bytes (plus a safety margin) can be written to the shared container's
    /// volume. Uses the "important usage" figure, which counts purgeable space the system
    /// will reclaim. Unknown means "assume yes".
    private static func hasSpace(for needed: Int64) -> Bool {
        let values = try? SharedContainer.root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return available >= needed + freeSpaceMargin
    }

    // MARK: - Metadata

    private static func mimeType(for url: URL, fallbackName: String) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
            return mime
        }
        if let ext = fallbackName.split(separator: ".").last.map(String.init),
           let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private static func captureDate(for url: URL, mime: String) async -> Date? {
        if mime.hasPrefix("image/") {
            return exifCaptureDate(url)
        }
        if mime.hasPrefix("video/") {
            return await videoCaptureDate(url)
        }
        return fileModificationDate(url)
    }

    private static func exifCaptureDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return fileModificationDate(url) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = formatter.date(from: raw) {
            return date
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let raw = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = formatter.date(from: raw) {
            return date
        }
        return fileModificationDate(url)
    }

    private static func videoCaptureDate(_ url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate),
           let date = try? await item.load(.dateValue) {
            return date
        }
        return fileModificationDate(url)
    }

    private static func fileModificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
