import Foundation
import Observation

/// The persisted `[UploadRecord]` list, in the shared App Group container so the
/// app and the Share Extension read and write the same state.
///
/// Both processes write the one file, so a write never replaces the file with this
/// process's in-memory snapshot — that would erase records the other process added in
/// the meantime. Instead every mutation is queued as an *operation* (upsert / remove)
/// and applied to the **on-disk** list inside a single coordinated write. The file I/O
/// runs on a background queue, so state changes (one per chunk, per file) never block
/// the main actor.
@MainActor
@Observable
final class UploadStore {
    private(set) var records: [UploadRecord] = []

    @ObservationIgnored private let file: RecordsFile

    init(fileURL: URL = SharedContainer.recordsFile) {
        file = RecordsFile(url: fileURL)
        reload()
    }

    /// Re-reads the shared file (picking up records the other process wrote), after
    /// flushing anything this process still has queued.
    func reload() {
        records = file.load().sorted { $0.createdAt < $1.createdAt }
    }

    func record(id: String) -> UploadRecord? {
        records.first { $0.id == id }
    }

    func records(batchID: String) -> [UploadRecord] {
        records.filter { $0.batchID == batchID }.sorted { $0.createdAt < $1.createdAt }
    }

    func upsert(_ record: UploadRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        file.enqueue(.upsert(record))
    }

    /// Mutate one record in place and persist.
    func mutate(id: String, _ body: (inout UploadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        body(&records[index])
        file.enqueue(.upsert(records[index]))
    }

    /// Forgets every record (sign-out).
    func removeAll() {
        records = []
        file.enqueue(.removeAll)
    }

    func clearFinished() {
        let finished = Set(records.filter(\.isFinished).map(\.id))
        records.removeAll { finished.contains($0.id) }
        file.enqueue(.remove(finished))
    }
}

// MARK: - On-disk file

private enum RecordOp: Sendable {
    case upsert(UploadRecord)
    case remove(Set<String>)
    case removeAll
}

/// Serialises access to the records file. All reads and writes go through one queue and
/// `NSFileCoordinator`, and a write is always read-modify-write against what is on disk.
private final class RecordsFile: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.eeinspired.mantel.records", qos: .utility)
    private let lock = NSLock()
    private var pending: [RecordOp] = []

    init(url: URL) {
        self.url = url
    }

    func enqueue(_ op: RecordOp) {
        lock.withLock { pending.append(op) }
        queue.async { self.drain() }
    }

    func load() -> [UploadRecord] {
        queue.sync {
            drain()
            var loaded: [UploadRecord] = []
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
                loaded = decode(readURL)
            }
            return loaded
        }
    }

    /// Applies every queued operation in one coordinated read-modify-write.
    private func drain() {
        let ops = lock.withLock { () -> [RecordOp] in
            defer { pending = [] }
            return pending
        }
        guard !ops.isEmpty else { return }
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { writeURL in
            var list = decode(writeURL)
            for op in ops {
                switch op {
                case let .upsert(record):
                    if let index = list.firstIndex(where: { $0.id == record.id }) {
                        list[index] = record
                    } else {
                        list.append(record)
                    }
                case let .remove(ids):
                    list.removeAll { ids.contains($0.id) }
                case .removeAll:
                    list = []
                }
            }
            guard let data = try? JSONEncoder().encode(list) else { return }
            try? data.write(to: writeURL, options: .atomic)
        }
    }

    /// One undecodable record is skipped rather than costing the whole list; a file that
    /// isn't a JSON array at all is moved aside (not overwritten) so it can be inspected.
    private func decode(_ fileURL: URL) -> [UploadRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let lossy = try? JSONDecoder().decode([LossyRecord].self, from: data) else {
            let aside = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            Telemetry.shared.recordNonFatal(
                NSError(domain: "UploadStore", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "upload records unreadable, moved aside",
                ]),
                context: "upload_store"
            )
            return []
        }
        return lossy.compactMap(\.record)
    }
}

private struct LossyRecord: Decodable {
    let record: UploadRecord?

    init(from decoder: Decoder) throws {
        record = try? UploadRecord(from: decoder)
    }
}
