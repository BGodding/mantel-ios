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
    /// Server origin this upload is pinned to, so staging and the final `MOVE` stay on one
    /// host for the life of the upload even if the configured base URL changes later.
    let baseURL: String
    /// Fully-qualified, percent-encoded URL of the destination folder.
    let collectionURL: String
    /// Absolute path of the staged source file in the shared container.
    let stagedPath: String
    let sizeBytes: Int64
    let mtimeEpochSeconds: Int64?
    let mode: UploadMode
    let createdAt: Date

    var state: UploadState
    var errorKind: UploadError?
    var attempt: Int
    /// How many times a name clash renamed this file (`IMG (1).jpg`, `IMG (2).jpg`, …).
    var nameIndex: Int

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
        baseURL: String,
        collectionURL: String,
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
        self.baseURL = baseURL
        self.collectionURL = collectionURL
        self.stagedPath = stagedPath
        self.sizeBytes = sizeBytes
        self.mtimeEpochSeconds = mtimeEpochSeconds
        self.mode = mode
        createdAt = Date()
        state = .waiting
        attempt = 0
        nameIndex = 0
        totalChunks = 0
        completedChunks = []
    }

    /// Bookkeeping fields fall back to defaults, so a record written by an older build
    /// (before a field existed) still decodes instead of being dropped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        batchID = try container.decode(String.self, forKey: .batchID)
        displayName = try container.decode(String.self, forKey: .displayName)
        destinationLabel = try container.decode(String.self, forKey: .destinationLabel)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        collectionURL = try container.decode(String.self, forKey: .collectionURL)
        stagedPath = try container.decode(String.self, forKey: .stagedPath)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        mtimeEpochSeconds = try container.decodeIfPresent(Int64.self, forKey: .mtimeEpochSeconds)
        mode = try container.decode(UploadMode.self, forKey: .mode)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        state = try container.decodeIfPresent(UploadState.self, forKey: .state) ?? .waiting
        errorKind = try container.decodeIfPresent(UploadError.self, forKey: .errorKind)
        attempt = try container.decodeIfPresent(Int.self, forKey: .attempt) ?? 0
        nameIndex = try container.decodeIfPresent(Int.self, forKey: .nameIndex) ?? 0
        uploadID = try container.decodeIfPresent(String.self, forKey: .uploadID)
        totalChunks = try container.decodeIfPresent(Int.self, forKey: .totalChunks) ?? 0
        completedChunks = try container.decodeIfPresent(Set<Int>.self, forKey: .completedChunks) ?? []
    }

    var isFinished: Bool { state == .succeeded || state == .failed }

    /// The name this attempt uploads as — `displayName`, numbered after a name clash.
    var remoteName: String { RemoteNames.numbered(displayName, nameIndex) }

    /// Fully-qualified, percent-encoded destination file URL for the current `nameIndex`.
    var finalURL: URL? {
        URL(string: collectionURL)?.appendingPathComponent(remoteName)
    }
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
    /// How many `name (n)` renames to try after a name clash before giving up.
    static let maxRenames = 9
    /// Client-side sanity cap on a single file.
    static let maxFileBytes: Int64 = 4 * 1024 * 1024 * 1024
}
