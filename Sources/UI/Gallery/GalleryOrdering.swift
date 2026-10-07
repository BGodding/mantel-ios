import Foundation

enum MediaFilter: String, CaseIterable, Identifiable {
    case all
    case photos
    case videos

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .photos: "Photos"
        case .videos: "Videos"
        }
    }
}

enum GallerySort: String, CaseIterable, Identifiable {
    case recentlyAdded
    case newest
    case oldest
    case largest
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentlyAdded: "Recently added"
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .largest: "Largest first"
        case .name: "Name"
        }
    }
}

extension [RemoteItem] {
    /// "Newest/Oldest" use the file's modified time, which the app sets to the photo's own
    /// date on upload (`X-OC-Mtime`) — effectively the date taken. "Recently added" uses
    /// the server's upload time.
    func filteredAndSorted(_ filter: MediaFilter, _ sort: GallerySort) -> [RemoteItem] {
        let visible: [RemoteItem] = switch filter {
        case .all: self
        case .photos: self.filter(\.isImage)
        case .videos: self.filter(\.isVideo)
        }
        return switch sort {
        case .recentlyAdded: visible.sorted { $0.addedAt > $1.addedAt }
        case .newest: visible.sorted { $0.lastModified > $1.lastModified }
        case .oldest: visible.sorted { $0.lastModified < $1.lastModified }
        case .largest: visible.sorted { $0.sizeBytes > $1.sizeBytes }
        case .name: visible.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
    }
}
