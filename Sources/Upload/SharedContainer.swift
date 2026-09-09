import Foundation

/// Locations inside the App Group container, shared by the app and the extension.
enum SharedContainer {
    static var root: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Config.appGroupIdentifier)
            ?? FileManager.default.temporaryDirectory
    }

    /// `uploads/` — staged source files, one sub-directory per batch.
    static var uploadsDir: URL {
        let url = root.appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func batchDir(_ batchID: String) -> URL {
        let url = uploadsDir.appendingPathComponent(batchID, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `<batch>/<recordID>.chunks/` — the split chunk files for a chunked upload.
    static func chunksDir(batchID: String, recordID: String) -> URL {
        let url = batchDir(batchID).appendingPathComponent("\(recordID).chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The persisted `[UploadRecord]` store.
    static var recordsFile: URL {
        root.appendingPathComponent("upload_records.json")
    }

    /// Delete batch directories older than 6h — stale staging from a batch that
    /// never finished (mirrors the Android `MediaStaging.sweepStale`).
    static func sweepStale() {
        let cutoff = Date().addingTimeInterval(-6 * 60 * 60)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: uploadsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }
}
