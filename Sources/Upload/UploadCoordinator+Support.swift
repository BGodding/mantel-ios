import Foundation

// Pure helpers and post-processing split out of `UploadCoordinator` to keep it readable.

extension UploadCoordinator {
    /// Descriptors (`<recordID>|<chunk>`) of every task the session is still carrying.
    func liveDescriptors() async -> Set<String> {
        _ = session
        var live = Set<String>()
        for background in Array(sessions.values) {
            let tasks = await withCheckedContinuation { (continuation: CheckedContinuation<[URLSessionTask], Never>) in
                background.getAllTasks { continuation.resume(returning: $0) }
            }
            live.formUnion(tasks.compactMap(\.taskDescription))
        }
        return live
    }

    /// Maps a non-success WebDAV result to the terminal error it carries, or nil for
    /// `.success` / retriable (`.serverError` / `.network`).
    func terminalError(for result: WebDAVResult) -> UploadError? {
        switch result {
        case .unauthorized: .auth
        case .forbidden: .forbidden
        case .destinationMissing: .destMissing
        case .conflict: .conflict
        case .quotaExceeded: .quota
        case .rejected: .rejected
        case .success, .serverError, .network: nil
        }
    }

    func descriptor(_ recordID: String, chunk: Int) -> String { "\(recordID)|\(chunk)" }

    func parse(_ raw: String) -> (recordID: String, chunk: Int)? {
        let parts = raw.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, let chunk = Int(parts[1]) else { return nil }
        return (String(parts[0]), chunk)
    }

    nonisolated static func chunkName(_ index: Int) -> String {
        let digits = String(index)
        let padding = max(0, UploadTuning.chunkNameWidth - digits.count)
        return String(repeating: "0", count: padding) + digits
    }

    /// Writes `<batch>/<recordID>.chunks/<000…>` files, skipping any already
    /// present. Returns the total chunk count.
    nonisolated static func splitIntoChunks(
        stagedPath: String,
        batchID: String,
        recordID: String
    ) throws -> Int {
        let dir = SharedContainer.chunksDir(batchID: batchID, recordID: recordID)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: stagedPath))
        defer { try? handle.close() }

        var index = 0
        while true {
            let data = try handle.read(upToCount: UploadTuning.chunkSizeBytes) ?? Data()
            if data.isEmpty { break }
            let chunkURL = dir.appendingPathComponent(chunkName(index))
            if !FileManager.default.fileExists(atPath: chunkURL.path) {
                try data.write(to: chunkURL, options: .atomic)
            }
            index += 1
            if data.count < UploadTuning.chunkSizeBytes { break }
        }
        return max(index, 1)
    }
}

// MARK: - Cleanup and reporting

extension UploadCoordinator {
    func cleanUp(_ record: UploadRecord) {
        try? FileManager.default.removeItem(atPath: record.stagedPath)
        let chunksDir = SharedContainer.chunksDir(batchID: record.batchID, recordID: record.id)
        try? FileManager.default.removeItem(at: chunksDir)
        let batchDir = SharedContainer.batchDir(record.batchID)
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: batchDir.path),
           contents.isEmpty {
            try? FileManager.default.removeItem(at: batchDir)
        }
    }

    func report(_ record: UploadRecord, state: UploadState, error: UploadError?) {
        let outcome = state == .succeeded ? "success" : (error?.rawValue ?? "failed")
        let sizeMB = record.sizeBytes > 0 ? record.sizeBytes / (1024 * 1024) : -1
        Telemetry.shared.event(
            Telemetry.Events.uploadResult,
            [
                "outcome": outcome,
                "chunked": record.mode == .chunked,
                "size_mb": sizeMB,
                "attempt": record.attempt,
                "renames": record.nameIndex,
            ]
        )
        // Outcomes that mean the app or server did something unexpected (not a user-fixable
        // refusal). Actionable without identifying anything: outcome, transport, size, attempt.
        guard error == .rejected || error == .server || error == .network else { return }
        Telemetry.shared.setKey("upload_last_outcome", outcome)
        Telemetry.shared.recordNonFatal(
            NSError(domain: "UploadFailed", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "upload failed: outcome=\(outcome) chunked=\(record.mode == .chunked) "
                    + "size_mb=\(sizeMB) attempt=\(record.attempt)",
            ]),
            context: "upload_failed"
        )
    }
}
