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

enum MediaStaging {
    enum StagingError: Error {
        case notLoadable
        case tooLarge(Int64)
        case copyFailed
    }

    private static let maxNameLength = 200

    /// Copies one item provider's file into `uploads/<batchID>/` and returns its
    /// metadata. Async because `loadFileRepresentation` is.
    static func stage(_ item: SendableItemProvider, batchID: String) async throws -> StagedFile {
        let provider = item.provider
        let (tempURL, suggestedName) = try await loadFile(from: provider)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let size = fileSize(tempURL)
        guard size <= UploadTuning.maxFileBytes else { throw StagingError.tooLarge(size) }

        let displayName = safeRemoteName(suggestedName ?? tempURL.lastPathComponent)
        let destination = uniqueDestination(displayName: displayName, batchID: batchID)

        do {
            try FileManager.default.copyItem(at: tempURL, to: destination)
        } catch {
            throw StagingError.copyFailed
        }

        let mime = mimeType(for: tempURL, fallbackName: displayName)
        let capture = await captureDate(for: destination, mime: mime)

        return StagedFile(
            path: destination.path,
            displayName: displayName,
            mimeType: mime,
            sizeBytes: fileSize(destination),
            captureEpochSeconds: capture.map { Int64($0.timeIntervalSince1970) }
        )
    }

    static func sweepStale() {
        SharedContainer.sweepStale()
    }

    // MARK: - Loading

    private static func loadFile(
        from provider: NSItemProvider
    ) async throws -> (url: URL, suggestedName: String?) {
        let type = preferredType(for: provider)
        // Pull the only value we need off the non-Sendable provider before the
        // @Sendable completion closure so it isn't captured across the boundary.
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url, error == nil else {
                    continuation.resume(throwing: error ?? StagingError.notLoadable)
                    return
                }
                // The callback URL is valid only until this closure returns — copy now.
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)
                do {
                    try FileManager.default.copyItem(at: url, to: temp)
                    let named = suggestedName.map {
                        url.pathExtension.isEmpty ? $0 : "\($0).\(url.pathExtension)"
                    } ?? suggestedName
                    continuation.resume(returning: (temp, named))
                } catch {
                    continuation.resume(throwing: StagingError.copyFailed)
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

    // MARK: - Name safety

    /// Name used for the WebDAV path. Keeps the human-readable filename but strips
    /// anything that could alter the path: directory separators, leading dots
    /// (`.` / `..`), control characters. Length-capped, with a generated fallback.
    private static func safeRemoteName(_ raw: String) -> String {
        let lastSegment = raw
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last.map(String.init) ?? raw
        var cleaned = String(lastSegment.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        })
        while let first = cleaned.first, first == "." || first == " " {
            cleaned.removeFirst()
        }
        cleaned = String(cleaned.prefix(maxNameLength))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "upload_\(Int(Date().timeIntervalSince1970))" : cleaned
    }

    private static func uniqueDestination(displayName: String, batchID: String) -> URL {
        let dir = SharedContainer.batchDir(batchID)
        let sanitised = String(displayName.map { char in
            char.isLetter || char.isNumber || char == "." || char == "_" || char == "-" ? char : "_"
        })
        let local = sanitised.isEmpty ? "upload" : sanitised
        var candidate = dir.appendingPathComponent(local)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        let stem = (local as NSString).deletingPathExtension
        let ext = (local as NSString).pathExtension
        let suffixed = "\(stem)_\(Int(Date().timeIntervalSince1970 * 1000))"
        candidate = dir.appendingPathComponent(ext.isEmpty ? suffixed : "\(suffixed).\(ext)")
        return candidate
    }
}
