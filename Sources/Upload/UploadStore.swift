import Foundation
import Observation

/// The persisted `[UploadRecord]` list, in the shared App Group container so the
/// app and the Share Extension read and write the same state.
///
/// Deliberately simple: load the whole file, mutate, write the whole file. The
/// list is short (one entry per file in a share batch) and writes are infrequent
/// (one per task state change), so there is no need for anything cleverer.
@MainActor
@Observable
final class UploadStore {
    private(set) var records: [UploadRecord] = []

    private let fileURL = SharedContainer.recordsFile
    private let coordinator = NSFileCoordinator()

    init() {
        reload()
    }

    func reload() {
        var coordinationError: NSError?
        var loaded: [UploadRecord] = []
        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([UploadRecord].self, from: data)
            else { return }
            loaded = decoded
        }
        records = loaded.sorted { $0.createdAt < $1.createdAt }
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
        persist()
    }

    /// Mutate one record in place and persist.
    func mutate(id: String, _ body: (inout UploadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        body(&records[index])
        persist()
    }

    func clearFinished() {
        records.removeAll { $0.isFinished }
        persist()
    }

    private func persist() {
        let snapshot = records
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
