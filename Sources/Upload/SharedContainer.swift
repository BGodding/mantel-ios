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

    /// Removes batch directories older than 6h that no queued or running upload still
    /// needs (`activeBatchIDs`). A directory's age alone must not decide: a batch shared
    /// while offline can legitimately wait longer than that for a connection.
    static func sweepStale(activeBatchIDs: Set<String>) {
        let cutoff = Date().addingTimeInterval(-6 * 60 * 60)
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: uploadsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries where !activeBatchIDs.contains(entry.lastPathComponent) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    /// Removes every staged file and the upload records (sign-out).
    static func deleteAll() {
        try? FileManager.default.removeItem(at: uploadsDir)
        try? FileManager.default.removeItem(at: recordsFile)
    }
}
