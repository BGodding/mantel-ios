import Foundation

/// Owns every byte transfer.
///
/// All transfers run as tasks on a **background** `URLSession`
/// (`sharedContainerIdentifier` = the App Group). Background upload tasks are handed
/// off to `nsurlsessiond` and keep running while the app is suspended, backgrounded,
/// or terminated — satisfying Requirements §6.4 and the "large background upload
/// survives suspension" acceptance test.
///
/// Each process owns its own session identifier (`Config.ownSessionIdentifier`): Apple
/// requires the Share Extension and its containing app not to share one. When the
/// extension has gone, the system launches the app with the extension's identifier and
/// the app re-attaches to that session to receive the completions. Persisted per-file
/// state lives in `UploadStore`, in the shared container, so both processes and both UIs
/// see the same thing.
///
/// The small control requests (`MKCOL`, `MOVE`) and the chunk splitting are not
/// background-session work, so every such operation runs as *tracked work* under a
/// `ProcessInfo` expiring activity: the system keeps the process alive while it is
/// running, and `urlSessionDidFinishEvents` waits for it before telling the system the
/// wake-up is done.
///
/// - Simple upload (< 8 MiB): one `PUT` upload task from the staged file.
/// - Chunked upload (≥ 8 MiB, API Contract §4): `MKCOL` a staging collection,
///   split the file into 10 MiB chunk files, `PUT` each as its own background
///   task, then `MOVE .file` to assemble. `MKCOL` / `MOVE` are tiny requests run
///   with `async`/`await` on a foreground session; the byte-carrying chunk `PUT`s
///   are what go through the background session.
///
/// Retries are safe: the staging collection is keyed by the record's stable upload id, so a
/// retry resumes where the last attempt stopped, and an existing file is never overwritten —
/// a name clash is resolved by numbering (`IMG (1).jpg`).
@MainActor
final class UploadCoordinator: NSObject, URLSessionDataDelegate {
    static let shared = UploadCoordinator()

    let store = UploadStore()

    /// Completion handlers from the app delegate's `handleEventsForBackgroundURLSession`,
    /// keyed by session identifier. Called once the wake-up's work is done.
    var backgroundCompletionHandlers: [String: () -> Void] = [:]

    private let credentialStore = KeychainCredentialStore()
    private var clients: [String: NextcloudClient] = [:]
    /// Records with a retry already scheduled — several chunk tasks can fail together, and
    /// each must not burn an attempt of its own.
    private var pendingRetries: Set<String> = []

    var sessions: [String: URLSession] = [:]

    /// This process's own background session.
    var session: URLSession { backgroundSession(Config.ownSessionIdentifier) }

    private func backgroundSession(_ identifier: String) -> URLSession {
        if let existing = sessions[identifier] { return existing }
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sharedContainerIdentifier = Config.appGroupIdentifier
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.httpMaximumConnectionsPerHost = 4
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let created = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        sessions[identifier] = created
        return created
    }

    /// Instantiates the background session (so queued completions replay) without
    /// enqueuing anything. Call once at launch. `identifier` is the session the system
    /// woke the app for (the extension's, when its uploads finished), if any.
    func attach(identifier: String? = nil) {
        _ = session
        if let identifier, Config.allSessionIdentifiers.contains(identifier) {
            _ = backgroundSession(identifier)
        }
    }

    /// The app also adopts the Share Extension's session while it still has unfinished
    /// work, so those in-flight tasks are seen (and not started a second time).
    private func attachForeignSessionIfNeeded() {
        guard !Config.isExtension, store.records.contains(where: { !$0.isFinished }) else { return }
        _ = backgroundSession(Config.extensionSessionIdentifier)
    }

    // MARK: - Tracked work

    private var trackedWork: [UUID: Task<Void, Never>] = [:]
    private var activityGate: DispatchSemaphore?

    /// Runs `work` while holding a `ProcessInfo` expiring activity (shared by everything
    /// tracked at once), so `MKCOL` / chunk splitting / `MOVE` aren't cut off the moment the
    /// app or extension is backgrounded.
    private func track(_ work: @escaping @MainActor @Sendable () async -> Void) {
        if trackedWork.isEmpty {
            let gate = DispatchSemaphore(value: 0)
            activityGate = gate
            ProcessInfo.processInfo.performExpiringActivity(withReason: "com.eeinspired.mantel.upload") { expired in
                if !expired { gate.wait() }
            }
        }
        let id = UUID()
        trackedWork[id] = Task {
            await work()
            trackedWork[id] = nil
            if trackedWork.isEmpty {
                activityGate?.signal()
                activityGate = nil
            }
        }
    }

    /// Suspends until every tracked operation has finished. The Share Extension awaits this
    /// after enqueueing so it isn't torn down before `MKCOL` / chunk tasks exist.
    func waitUntilIdle() async {
        while let task = trackedWork.values.first { await task.value }
    }

    /// One client per pinned origin — each owns its own URL sessions.
    private func client(for record: UploadRecord) -> NextcloudClient {
        if let existing = clients[record.baseURL] { return existing }
        let created = NextcloudClient(baseURL: URL(string: record.baseURL) ?? Config.baseURL)
        clients[record.baseURL] = created
        return created
    }

    // MARK: - Enqueue

    /// Files are already copied into the shared container by `MediaStaging`.
    /// Returns the batch id the status UI observes.
    @discardableResult
    func enqueue(destination: Frame, userId: String, staged: [StagedFile]) -> String {
        sweepStale()
        let batchID = UUID().uuidString
        // Pin the origin for this batch so staging + MOVE stay on one server.
        let base = Config.baseURL
        let collection = destination.uploadCollectionURL(baseURL: base, userId: userId)

        for file in staged {
            let mode: UploadMode =
                file.sizeBytes >= UploadTuning.simpleUploadMaxBytes ? .chunked : .simple
            let record = UploadRecord(
                batchID: batchID,
                displayName: file.displayName,
                destinationLabel: destination.displayName,
                mimeType: file.mimeType,
                baseURL: base.absoluteString,
                collectionURL: collection.absoluteString,
                stagedPath: file.path,
                sizeBytes: file.sizeBytes,
                mtimeEpochSeconds: file.captureEpochSeconds,
                mode: mode
            )
            store.upsert(record)
            start(record.id)
        }

        Telemetry.shared.event(Telemetry.Events.uploadEnqueued, ["count": staged.count])
        return batchID
    }

    /// Drops stale staging directories that no queued or running upload still needs.
    func sweepStale() {
        store.reload()
        let active = Set(store.records.filter { !$0.isFinished }.map(\.batchID))
        MediaStaging.sweepStale(activeBatchIDs: active)
    }

    /// Re-drive anything unfinished — call at launch and from
    /// `urlSessionDidFinishEvents`. Records with a live task are left alone.
    func reconcile() async {
        store.reload()
        attachForeignSessionIfNeeded()
        let liveIDs = await Set(liveDescriptors().compactMap { parse($0)?.recordID })
        for record in store.records where !record.isFinished && !liveIDs.contains(record.id) {
            start(record.id)
        }
    }

    /// Sign-out: cancel everything in flight and delete every staged copy of the user's
    /// photos and every record. With `credentials`, also best-effort removes the server-side
    /// staging collections of unfinished chunked uploads so they aren't orphaned.
    func cancelAllAndWipe(credentials: Credentials?) {
        if let credentials {
            for record in store.records where record.mode == .chunked && !record.isFinished {
                guard let uploadID = record.uploadID else { continue }
                let pinned = client(for: record)
                Task { await pinned.discardStaging(credentials, uploadID: uploadID) }
            }
        }
        _ = session
        for background in sessions.values {
            background.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        }
        SharedContainer.deleteAll()
        store.removeAll()
        clients.removeAll()
        pendingRetries.removeAll()
    }

    // MARK: - Per-record driving

    private func start(_ recordID: String) {
        guard let record = store.record(id: recordID), !record.isFinished else { return }
        guard credentialStore.load() != nil else {
            // Signed out (e.g. the app password was revoked): keep the staged file and the
            // record, so signing back in resumes it instead of losing the user's photo.
            store.mutate(id: recordID) { $0.state = .waiting; $0.errorKind = .noCredentials }
            return
        }
        guard FileManager.default.fileExists(atPath: record.stagedPath) else {
            finish(recordID, state: .failed, error: .unreadableFile)
            return
        }
        track { await self.drive(recordID) }
    }

    private func drive(_ recordID: String) async {
        guard let record = store.record(id: recordID), !record.isFinished,
              let creds = credentialStore.load() else { return }
        if await alreadyUploaded(record, creds) {
            finish(recordID, state: .succeeded, error: nil)
            return
        }
        switch record.mode {
        case .simple: startSimple(recordID)
        case .chunked: await startChunked(recordID)
        }
    }

    /// A previous attempt may have finished but lost its response. Without a capture time to
    /// match on we can't tell that file from an unrelated one, so we don't guess (a duplicate
    /// beats a loss).
    private func alreadyUploaded(_ record: UploadRecord, _ creds: Credentials) async -> Bool {
        let mayHaveLanded = record.attempt > 0 || record.state != .waiting
        guard mayHaveLanded, record.nameIndex == 0,
              let mtime = record.mtimeEpochSeconds, let url = record.finalURL else { return false }
        return await client(for: record).remoteFileMatches(
            creds, fileURL: url, sizeBytes: record.sizeBytes, mtimeSeconds: mtime
        )
    }

    private func startSimple(_ recordID: String) {
        guard let record = store.record(id: recordID),
              let creds = credentialStore.load(),
              let url = record.finalURL else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(creds.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue(record.mimeType, forHTTPHeaderField: "Content-Type")
        // Never replace an existing file: a clash comes back as 412 and is renamed.
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        if let mtime = record.mtimeEpochSeconds {
            request.setValue(String(mtime), forHTTPHeaderField: "X-OC-Mtime")
        }
        let task = session.uploadTask(with: request, fromFile: URL(fileURLWithPath: record.stagedPath))
        task.taskDescription = descriptor(record.id, chunk: -1)
        store.mutate(id: record.id) { $0.state = .uploading }
        task.resume()
    }

    private func startChunked(_ recordID: String) async {
        guard let record = store.record(id: recordID), let creds = credentialStore.load() else { return }

        // 1. Staging collection.
        let uploadID = record.uploadID ?? UUID().uuidString
        if record.uploadID == nil { store.mutate(id: recordID) { $0.uploadID = uploadID } }
        if record.completedChunks.isEmpty,
           await !ensureStagingCollection(record, creds: creds, uploadID: uploadID) {
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
            retryOrFail(recordID, kind: .unreadableFile)
            return
        }
        store.mutate(id: recordID) { $0.totalChunks = chunkCount; $0.state = .uploading }

        // 3. One background PUT per missing chunk (skipping any a live task is already sending).
        guard let fresh = store.record(id: recordID) else { return }
        if fresh.completedChunks.count >= chunkCount {
            await assemble(recordID)
            return
        }
        let live = await liveDescriptors()
        let chunksDir = SharedContainer.chunksDir(batchID: batchID, recordID: recordID)
        let base = URL(string: record.baseURL) ?? Config.baseURL
        let stagingRoot = base
            .appendingPathComponent("remote.php/dav/uploads")
            .appendingPathComponent(creds.userId)
            .appendingPathComponent(uploadID)

        for index in 0 ..< chunkCount where !fresh.completedChunks.contains(index) {
            let taskDescription = descriptor(recordID, chunk: index)
            if live.contains(taskDescription) { continue }
            let name = Self.chunkName(index)
            var request = URLRequest(url: stagingRoot.appendingPathComponent(name))
            request.httpMethod = "PUT"
            request.setValue(creds.basicAuthHeader, forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: request, fromFile: chunksDir.appendingPathComponent(name))
            task.taskDescription = taskDescription
            task.resume()
        }
    }

    /// `MKCOL` the staging collection. Returns `true` to proceed; on a terminal or
    /// retriable failure it finishes/reschedules the record and returns `false`.
    private func ensureStagingCollection(_ record: UploadRecord, creds: Credentials, uploadID: String) async -> Bool {
        let result = await client(for: record).makeCollection(creds, uploadID: uploadID)
        switch result {
        case .success: return true
        case .serverError, .network: retryOrFail(record.id, kind: .server)
        default: finish(record.id, state: .failed, error: terminalError(for: result) ?? .server)
        }
        return false
    }

    private func assemble(_ recordID: String) async {
        guard let record = store.record(id: recordID), let uploadID = record.uploadID,
              let creds = credentialStore.load(), let destination = record.finalURL else { return }

        store.mutate(id: recordID) { $0.state = .assembling }
        let result = await client(for: record).assembleChunks(
            creds,
            uploadID: uploadID,
            destinationURL: destination,
            totalBytes: record.sizeBytes,
            mtime: record.mtimeEpochSeconds
        )
        switch result {
        case .success: finish(recordID, state: .succeeded, error: nil)
        case .conflict: await renameOrFail(recordID, reassemble: true)
        case .serverError, .network: retryOrFail(recordID, kind: .server)
        default: abortChunked(recordID, error: terminalError(for: result) ?? .server)
        }
    }

    /// A name clash (412): try `name (1)`, `name (2)`… before giving up. The chunks are
    /// already on the server, so a chunked upload just re-`MOVE`s to the new name.
    private func renameOrFail(_ recordID: String, reassemble: Bool) async {
        guard let record = store.record(id: recordID) else { return }
        guard record.nameIndex < UploadTuning.maxRenames else {
            if reassemble {
                abortChunked(recordID, error: .conflict)
            } else {
                finish(recordID, state: .failed, error: .conflict)
            }
            return
        }
        store.mutate(id: recordID) { $0.nameIndex += 1 }
        if reassemble { await assemble(recordID) } else { start(recordID) }
    }

    // MARK: - Completion handling (called from the session delegate, on the main actor)

    func handleCompletion(descriptor raw: String?, status: Int?, transportError: Error?) {
        guard let raw, let (recordID, chunkIndex) = parse(raw) else { return }
        // A record the other process created (extension → app) isn't in memory yet.
        if store.record(id: recordID) == nil { store.reload() }
        guard let record = store.record(id: recordID), !record.isFinished else { return }

        if let transportError {
            if (transportError as? URLError)?.code == .cancelled { return }
            retryOrFail(recordID, kind: .network)
            return
        }

        let result = NextcloudClient.classify(status ?? 0)
        if chunkIndex < 0 {
            handleSimpleResult(result, recordID: recordID)
        } else {
            handleChunkResult(result, recordID: recordID, chunkIndex: chunkIndex)
        }
    }

    private func handleSimpleResult(_ result: WebDAVResult, recordID: String) {
        switch result {
        case .success:
            finish(recordID, state: .succeeded, error: nil)
        case .serverError:
            retryOrFail(recordID, kind: .server)
        case .network:
            retryOrFail(recordID, kind: .network)
        case .conflict:
            track { await self.renameOrFail(recordID, reassemble: false) }
        default:
            finish(recordID, state: .failed, error: terminalError(for: result))
        }
    }

    private func handleChunkResult(_ result: WebDAVResult, recordID: String, chunkIndex: Int) {
        switch result {
        case .success:
            // Progress resets the retry budget: `maxAttempts` is for a stuck upload, not a
            // long one that hits a few transient failures along the way.
            store.mutate(id: recordID) {
                $0.completedChunks.insert(chunkIndex)
                $0.attempt = 0
            }
            if let updated = store.record(id: recordID),
               updated.totalChunks > 0,
               updated.completedChunks.count >= updated.totalChunks {
                track { await self.assemble(recordID) }
            }
        case .serverError, .network:
            retryOrFail(recordID, kind: .server)
        default:
            abortChunked(recordID, error: terminalError(for: result) ?? .server)
        }
    }

    // MARK: - Terminal + retry

    private func retryOrFail(_ recordID: String, kind: UploadError) {
        guard let record = store.record(id: recordID) else { return }
        guard !pendingRetries.contains(recordID) else { return }

        let nextAttempt = record.attempt + 1
        guard nextAttempt < UploadTuning.maxAttempts else {
            if record.mode == .chunked { discardStaging(record) }
            finish(recordID, state: .failed, error: kind)
            return
        }
        store.mutate(id: recordID) { $0.attempt = nextAttempt; $0.state = .waiting }
        pendingRetries.insert(recordID)
        let delay = min(pow(2.0, Double(nextAttempt)), 60)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            self.pendingRetries.remove(recordID)
            self.start(recordID)
        }
    }

    private func abortChunked(_ recordID: String, error: UploadError) {
        if let record = store.record(id: recordID) { discardStaging(record) }
        finish(recordID, state: .failed, error: error)
    }

    /// Best-effort removal of the server-side staging collection once the outcome is final.
    private func discardStaging(_ record: UploadRecord) {
        guard let uploadID = record.uploadID, let creds = credentialStore.load() else { return }
        let client = client(for: record)
        Task { await client.discardStaging(creds, uploadID: uploadID) }
    }

    private func finish(_ recordID: String, state: UploadState, error: UploadError?) {
        guard let record = store.record(id: recordID) else { return }
        store.mutate(id: recordID) {
            $0.state = state
            $0.errorKind = error
        }
        if state == .succeeded || state == .failed {
            cleanUp(record)
        }
        report(record, state: state, error: error)
    }

    // MARK: - Helpers
}
