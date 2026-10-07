import Foundation

/// Why an upload ended for good. Persisted in `UploadRecord` by raw value; the raw
/// values keep the strings earlier builds wrote, so old records still decode.
enum UploadError: String, Codable, Equatable {
    case auth
    case noCredentials = "no_credentials"
    case forbidden
    case conflict
    case destMissing = "dest_missing"
    case quota
    case network
    case server
    case rejected
    case unreadableFile = "unreadable_file"
    case badInput = "bad_input"
}
