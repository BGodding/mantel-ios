import Foundation

/// Owns every byte transfer.
///
/// All transfers run as tasks on one **background** `URLSession`
/// (`Config.backgroundSessionIdentifier`, `sharedContainerIdentifier` = the App
/// Group). Background upload tasks are handed off to `nsurlsessiond` and keep
/// running while the app is suspended, backgrounded, or terminated — satisfying
/// Requirements §6.4 and the "large background upload survives suspension"
/// acceptance test.
///
/// The same session identifier is used from the app and the Share Extension so
/// whichever process is alive next reattaches and receives the completion events
/// the other one missed. Persisted per-file state lives in `UploadStore`, in the
/// shared container, so both processes and both UIs see the same thing.
///
/// - Simple upload (< 8 MiB): one `PUT` upload task from the staged file.
/// - Chunked upload (≥ 8 MiB, API Contract §4): `MKCOL` a staging collection,
///   split the file into 10 MiB chunk files, `PUT` each as its own background
///   task, then `MOVE .file` to assemble. `MKCOL` / `MOVE` are tiny requests run
///   with `async`/`await` on a foreground session; the byte-carrying chunk `PUT`s
///   are what go through the background session.
@MainActor
final class UploadCoordinator: NSObject {
    static let shared = UploadCoordinator()

    let store = UploadStore()

    /// Set by the app delegate's `handleEventsForBackgroundURLSession`.
    var backgroundCompletionHandler: (() -> Void)?

    private let credentialStore = KeychainCredentialStore()
    private let control = NextcloudClient()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Config.backgroundSessionIdentifier)
        config.sharedContainerIdentifier = Config.appGroupIdentifier
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.httpMaximumConnectionsPerHost = 4
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    /// Instantiates the background session (so queued completions replay) without
    /// enqueuing anything. Call once at launch.
    func attach() {
        _ = session
    }

    // MARK: - Enqueue

    /// Stages are already copied into the shared container by `MediaStaging`.
    /// Returns the batch id the status UI observes.
    @discardableResult
    func enqueue(destination: Frame, username: String, staged: [StagedFile]) -> String {
        MediaStaging.sweepStale()
        let batchID = UUID().uuidString
        let collection = destination.uploadCollectionURL(username: username)

        for file in staged {
            let finalURL = collection.appendingPathComponent(file.displayName)
            let mode: UploadMode =
                file.sizeBytes >= UploadTuning.simpleUploadMaxBytes ? .chunked : .simple
            let record = UploadRecord(
                batchID: batchID,
                displayName: file.displayName,
                destinationLabel: destination.displayName,
                mimeType: file.mimeType,
                finalURL: finalURL.absoluteString,
                stagedPath: file.path,
                sizeBytes: file.sizeBytes,
                mtimeEpochSeconds: file.captureEpochSeconds,
                mode: mode
            )
            store.upsert(record)
            start(record.id)
        }

        Telemetry.shared.event(
            Telemetry.Events.uploadEnqueued,
            ["count": staged.count]
        )
        return batchID
    }

    /// Re-drive anything unfinished — call at launch and from
    /// `urlSessionDidFinishEvents`. Records with a live task are left alone.
    func reconcile() async {
        store.reload()
        let liveIDs = await liveRecordIDs()
        for record in store.records where !record.isFinished {
            if !liveIDs.contains(record.id) {
                start(record.id)
            }
        }
    }

    // MARK: - Per-record driving

    private func start(_ recordID: String) {
        guard let record = store.record(id: recordID), !record.isFinished else { return }
        guard credentialStore.load() != nil else {
            finish(recordID, state: .failed, errorKind: "no_credentials")
            return
        }
        guard FileManager.default.fileExists(atPath: record.stagedPath) else {
            finish(recordID, state: .failed, errorKind: "unreadable_file")
            return
        }

        switch record.mode {
        case .simple:
            startSimple(record)
        case .chunked:
            Task { await startChunked(recordID) }
        }
    }

    private func startSimple(_ record: UploadRecord) {
        guard let creds = credentialStore.load(), let url = URL(string: record.finalURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(creds.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue(record.mimeType, forHTTPHeaderField: "Content-Type")
        if let mtime = record.mtimeEpochSeconds {
            request.setValue(String(mtime), forHTTPHeaderField: "X-OC-Mtime")
        }
        let task = session.uploadTask(with: request, fromFile: URL(fileURLWithPath: record.stagedPath))
        task.taskDescription = descriptor(record.id, chunk: -1)
        store.mutate(id: record.id) { $0.state = .uploading }
        task.resume()
    }

    private func startChunked(_ recordID: String) async {
        guard let record = store.record(id: recordID),
              let creds = credentialStore.load()
        else { return }

        // 1. Staging collection.
        let uploadID = record.uploadID ?? UUID().uuidString
        if record.uploadID == nil {
            store.mutate(id: recordID) { $0.uploadID = uploadID }
        }
        if record.completedChunks.isEmpty,
           await !ensureStagingCollection(recordID: recordID, creds: creds, uploadID: uploadID) {
            return
        }

        // 2. Split into chunk files (skip any already written).
        let stagedPath = record.stagedPath
        let batchID = record.batchID
        let chunkCount: Int
        do {
            chunkCount = try await Task.detached(priority: .utility) {
                try Self.splitIntoChunks(stagedPath: stagedPath, batchID: batchID, recordID: recordID)
            }.value
        } catch {
            retryOrFail(recordID, kind: "unreadable_file"); return
        }
        store.mutate(id: recordID) { $0.totalChunks = chunkCount; $0.state = .uploading }

        // 3. One background PUT per missing chunk.
        guard let fresh = store.record(id: recordID) else { return }
        let chunksDir = SharedContainer.chunksDir(batchID: record.batchID, recordID: recordID)
        let base = Config.baseURL
            .appendingPathComponent("remote.php/dav/uploads")
            .appendingPathComponent(creds.username)
            .appendingPathComponent(uploadID)

        if fresh.completedChunks.count >= chunkCount {
            await assemble(recordID)
            return
        }

        for index in 0 ..< chunkCount where !fresh.completedChunks.contains(index) {
            let name = Self.chunkName(index)
            let chunkFile = chunksDir.appendingPathComponent(name)
            var request = URLRequest(url: base.appendingPathComponent(name))
            request.httpMethod = "PUT"
            request.setValue(creds.basicAuthHeader, forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: request, fromFile: chunkFile)
            task.taskDescription = descriptor(recordID, chunk: index)
            task.resume()
        }
    }

    /// `MKCOL` the staging collection. Returns `true` to proceed; on a terminal or
    /// retriable failure it finishes/reschedules the record and returns `false`.
    private func ensureStagingCollection(
        recordID: String,
        creds: Credentials,
        uploadID: String
    ) async -> Bool {
        let result = await control.makeCollection(creds, uploadID: uploadID)
        if case .success = result { return true }
        if case .serverError = result { retryOrFail(recordID, kind: "server"); return false }
        if case .network = result { retryOrFail(recordID, kind: "server"); return false }
        finish(recordID, state: .failed, errorKind: terminalKind(for: result) ?? "server")
        return false
    }

    private func assemble(_ recordID: String) async {
        guard let record = store.record(id: recordID),
              let uploadID = record.uploadID,
              let creds = credentialStore.load(),
              let destinationURL = URL(string: record.finalURL)
        else { return }

        store.mutate(id: recordID) { $0.state = .assembling }
        let result = await control.assembleChunks(
            creds,
            uploadID: uploadID,
            destinationURL: destinationURL,
            totalBytes: record.sizeBytes,
            mtime: record.mtimeEpochSeconds
        )
        switch result {
        case .success:
            finish(recordID, state: .succeeded, errorKind: nil)
        case .unauthorized:
            abortChunked(recordID, uploadID: uploadID, creds: creds, kind: "auth")
        case .forbidden:
            abortChunked(recordID, uploadID: uploadID, creds: creds, kind: "forbidden")
        case .destinationMissing:
            abortChunked(recordID, uploadID: uploadID, creds: creds, kind: "dest_missing")
        case .quotaExceeded:
            abortChunked(recordID, uploadID: uploadID, creds: creds, kind: "quota")
        case .serverError, .network:
            retryOrFail(recordID, kind: "server")
        }
    }

    // MARK: - Completion handling (called from the session delegate, on the main actor)

    fileprivate func handleCompletion(descriptor raw: String?, status: Int?, transportError: Error?) {
        guard let raw, let (recordID, chunkIndex) = parse(raw),
              let record = store.record(id: recordID), !record.isFinished
        else { return }

        if let transportError {
            if (transportError as? URLError)?.code == .cancelled { return }
            retryOrFail(recordID, kind: "network")
            return
        }

        let result = NextcloudClient.classify(status ?? 0)
        if chunkIndex < 0 {
            handleSimpleResult(result, recordID: recordID)
        } else {
            handleChunkResult(result, recordID: recordID, chunkIndex: chunkIndex, record: record)
        }
    }

    /// Maps a non-success WebDAV result to the terminal error kind it carries, or
    /// nil for `.success` / retriable (`.serverError` / `.network`).
    private func terminalKind(for result: WebDAVResult) -> String? {
        switch result {
        case .unauthorized: "auth"
        case .forbidden: "forbidden"
        case .destinationMissing: "dest_missing"
        case .quotaExceeded: "quota"
        case .success, .serverError, .network: nil
        }
    }

    private func handleSimpleResult(_ result: WebDAVResult, recordID: String) {
        switch result {
        case .success:
            finish(recordID, state: .succeeded, errorKind: nil)
        case .serverError:
            retryOrFail(recordID, kind: "server")
        case .network:
            retryOrFail(recordID, kind: "network")
        case .unauthorized, .forbidden, .destinationMissing, .quotaExceeded:
            finish(recordID, state: .failed, errorKind: terminalKind(for: result))
        }
    }

    private func handleChunkResult(
        _ result: WebDAVResult,
        recordID: String,
        chunkIndex: Int,
        record: UploadRecord
    ) {
        if case .success = result {
            store.mutate(id: recordID) { $0.completedChunks.insert(chunkIndex) }
            if let updated = store.record(id: recordID),
               updated.totalChunks > 0,
               updated.completedChunks.count >= updated.totalChunks {
                Task { await assemble(recordID) }
            }
            return
        }
        if case .serverError = result { retryOrFail(recordID, kind: "server"); return }
        if case .network = result { retryOrFail(recordID, kind: "server"); return }

        let kind = terminalKind(for: result) ?? "server"
        if let uploadID = record.uploadID, let creds = credentialStore.load() {
            abortChunked(recordID, uploadID: uploadID, creds: creds, kind: kind)
        } else {
            finish(recordID, state: .failed, errorKind: kind)
        }
    }

    // MARK: - Terminal + retry

    private func retryOrFail(_ recordID: String, kind: String) {
        guard let record = store.record(id: recordID) else { return }
        let nextAttempt = record.attempt + 1
        guard nextAttempt < UploadTuning.maxAttempts else {
            if record.mode == .chunked, let uploadID = record.uploadID, let creds = credentialStore.load() {
                Task { await control.deleteCollection(creds, uploadID: uploadID) }
            }
            finish(recordID, state: .failed, errorKind: kind)
            return
        }
        store.mutate(id: recordID) { $0.attempt = nextAttempt; $0.state = .waiting }
        let delay = min(pow(2.0, Double(nextAttempt)), 60)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.start(recordID)
        }
    }

    private func abortChunked(_ recordID: String, uploadID: String, creds: Credentials, kind: String) {
        Task {
            let cleanup = await control.deleteCollection(creds, uploadID: uploadID)
            if cleanup != .success, cleanup != .destinationMissing {
                Telemetry.shared.recordNonFatal(
                    NSError(domain: "OrphanedStaging", code: 0,
                            userInfo: [NSLocalizedDescriptionKey: "cleanup=\(cleanup)"]),
                    context: "orphaned_upload_staging"
                )
            }
        }
        finish(recordID, state: .failed, errorKind: kind)
    }

    private func finish(_ recordID: String, state: UploadState, errorKind: String?) {
        guard let record = store.record(id: recordID) else { return }
        store.mutate(id: recordID) {
            $0.state = state
            $0.errorKind = errorKind
        }
        if state == .succeeded || state == .failed {
            cleanUp(record)
        }
        let outcome = state == .succeeded ? "success" : (errorKind ?? "failed")
        Telemetry.shared.event(
            Telemetry.Events.uploadResult,
            [
                "outcome": outcome,
                "chunked": record.mode == .chunked,
                "size_mb": record.sizeBytes > 0 ? record.sizeBytes / (1024 * 1024) : -1,
                "attempt": record.attempt,
            ]
        )
    }

    private func cleanUp(_ record: UploadRecord) {
        try? FileManager.default.removeItem(atPath: record.stagedPath)
        let chunksDir = SharedContainer.chunksDir(batchID: record.batchID, recordID: record.id)
        try? FileManager.default.removeItem(at: chunksDir)
        let batchDir = SharedContainer.batchDir(record.batchID)
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: batchDir.path),
           contents.isEmpty {
            try? FileManager.default.removeItem(at: batchDir)
        }
    }

    // MARK: - Helpers

    private func descriptor(_ recordID: String, chunk: Int) -> String { "\(recordID)|\(chunk)" }

    private func parse(_ raw: String) -> (String, Int)? {
        let parts = raw.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, let chunk = Int(parts[1]) else { return nil }
        return (String(parts[0]), chunk)
    }

    private func liveRecordIDs() async -> Set<String> {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let ids = tasks.compactMap { task -> String? in
                    guard let desc = task.taskDescription else { return nil }
                    return desc.split(separator: "|").first.map(String.init)
                }
                continuation.resume(returning: Set(ids))
            }
        }
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

// MARK: - Background session delegate

extension UploadCoordinator: URLSessionDataDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let descriptor = task.taskDescription
        let status = (task.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor in
            self.handleCompletion(descriptor: descriptor, status: status, transportError: error)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            await self.reconcile()
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
