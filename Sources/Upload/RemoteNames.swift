import Foundation

/// Turns provider-supplied file names into safe WebDAV path segments and staging file names.
enum RemoteNames {
    private static let maxNameBytes = 200
    private static let maxExtensionChars = 12

    /// Suffixes the server treats as in-flight uploads.
    private static let reservedSuffixes = [".part", ".filepart"]
    private static let forbiddenScalars: Set<Unicode.Scalar> = Set("<>:\"|?*\\/".unicodeScalars)

    /// Name used for the WebDAV path. Keeps the human-readable filename but strips anything
    /// that could alter the path or that the server rejects: directory separators, leading
    /// dots (`.` / `..`), control characters, Windows-reserved characters, trailing dots/spaces,
    /// and in-flight suffixes (`.part`). The 200-*byte* cap (filesystems limit bytes, not
    /// characters) trims the stem so the extension survives. Falls back to a generated name.
    static func safe(_ raw: String, fallbackStamp: Int = Int(Date().timeIntervalSince1970)) -> String {
        let base = raw.split(separator: "/", omittingEmptySubsequences: false).last
            .flatMap { $0.split(separator: "\\", omittingEmptySubsequences: false).last }
            .map(String.init) ?? raw
        let normalised = base.precomposedStringWithCanonicalMapping
        let scrubbed = String(String.UnicodeScalarView(normalised.unicodeScalars.map { scalar in
            isForbidden(scalar) ? "_" : scalar
        }))
        var cleaned = scrubbed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if reservedSuffixes.contains(where: { cleaned.lowercased().hasSuffix($0) }) {
            cleaned += "_"
        }
        cleaned = capBytes(cleaned).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "upload_\(fallbackStamp)" : cleaned
    }

    /// `IMG.jpg` → `IMG (2).jpg`; `index` = 0 keeps the name.
    static func numbered(_ name: String, _ index: Int) -> String {
        guard index > 0 else { return name }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return "\(name[..<dot]) (\(index))\(name[dot...])"
        }
        return "\(name) (\(index))"
    }

    /// Filesystem-safe name for the staged copy on disk (de-duplicated within `directory`).
    static func localFileName(_ safeName: String, in directory: URL) -> String {
        var cleaned = String(safeName.unicodeScalars.map { scalar -> Character in
            let isSafe = scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
            return isSafe ? Character(scalar) : "_"
        })
        cleaned = String(cleaned.prefix(maxNameBytes))
        if cleaned.isEmpty { cleaned = "upload" }
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(cleaned).path) {
            return cleaned
        }
        let unique = UUID().uuidString.prefix(8)
        let stem = (cleaned as NSString).deletingPathExtension
        let ext = (cleaned as NSString).pathExtension
        return ext.isEmpty ? "\(stem)_\(unique)" : "\(stem)_\(unique).\(ext)"
    }

    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || forbiddenScalars.contains(scalar)
    }

    private static func capBytes(_ name: String) -> String {
        guard name.utf8.count > maxNameBytes else { return name }
        var ext = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex,
           name.distance(from: dot, to: name.endIndex) <= maxExtensionChars {
            ext = String(name[dot...])
        }
        var stem = String(name.dropLast(ext.count))
        while !stem.isEmpty, (stem + ext).utf8.count > maxNameBytes {
            stem.removeLast()
        }
        return stem + ext
    }
}
