import Foundation

/// A picked/shared item copied into the shared container, with the metadata the
/// upload needs.
struct StagedFile: Equatable {
    /// Absolute path inside the App Group container.
    let path: String
    /// Sanitised name — used both for the UI and as the WebDAV filename.
    let displayName: String
    let mimeType: String
    let sizeBytes: Int64
    /// Capture date in epoch seconds for `X-OC-Mtime` (API Contract §3/§4), or nil.
    let captureEpochSeconds: Int64?
}

/// How a file is being transferred.
enum UploadMode: String, Codable {
    /// Single `PUT` — below `UploadTuning.simpleUploadMaxBytes`.
    case simple
    /// WebDAV chunking v2 — `MKCOL` → ordered chunk `PUT`s → `MOVE` (API Contract §4).
    case chunked
}

/// Lifecycle of one file's upload. Terminal states: `.succeeded`, `.failed`.
enum UploadState: String, Codable {
    case waiting // enqueued, no connectivity or not started
    case uploading // bytes in flight
    case assembling // chunked: all chunks up, MOVE in progress
    case succeeded
    case failed
}

/// Persisted record of one file's upload. Written to the shared container so the
/// app and the Share Extension observe the same state, and so an upload started
/// by the extension is still visible after the extension goes away.
struct UploadRecord: Codable, Identifiable, Equatable {
    let id: String
    let batchID: String

    let displayName: String
    let destinationLabel: String
    let mimeType: String
    /// Fully-qualified, percent-encoded destination file URL.
    let finalURL: String
    /// Absolute path of the staged source file in the shared container.
    let stagedPath: String
    let sizeBytes: Int64
    let mtimeEpochSeconds: Int64?
    let mode: UploadMode
    let createdAt: Date

    var state: UploadState
    var errorKind: String?
    var attempt: Int

    // Chunked-only bookkeeping.
    var uploadID: String?
    var totalChunks: Int
    var completedChunks: Set<Int>

    init(
        id: String = UUID().uuidString,
        batchID: String,
        displayName: String,
        destinationLabel: String,
        mimeType: String,
        finalURL: String,
        stagedPath: String,
        sizeBytes: Int64,
        mtimeEpochSeconds: Int64?,
        mode: UploadMode
    ) {
        self.id = id
        self.batchID = batchID
        self.displayName = displayName
        self.destinationLabel = destinationLabel
        self.mimeType = mimeType
        self.finalURL = finalURL
        self.stagedPath = stagedPath
        self.sizeBytes = sizeBytes
        self.mtimeEpochSeconds = mtimeEpochSeconds
        self.mode = mode
        createdAt = Date()
        state = .waiting
        attempt = 0
        totalChunks = 0
        completedChunks = []
    }

    var isFinished: Bool { state == .succeeded || state == .failed }
}

enum UploadTuning {
    /// Below this, a single `PUT`; at or above, chunked v2. Conservatively under
    /// Nextcloud's ~100 MiB single-`PUT` ceiling (API Contract §3), matching the
    /// Android client's 8 MiB split.
    static let simpleUploadMaxBytes: Int64 = 8 * 1024 * 1024
    /// 10 MiB chunks — resilient on flaky uplinks (API Contract §4).
    static let chunkSizeBytes: Int = 10 * 1024 * 1024
    /// Zero-padded, lexically sortable chunk names (API Contract §4).
    static let chunkNameWidth = 15
    static let maxAttempts = 5
    /// Client-side sanity cap on a single file.
    static let maxFileBytes: Int64 = 4 * 1024 * 1024 * 1024
}
