import Foundation

/// Streams a WebDAV `PROPFIND` `multistatus` body into `[RemoteItem]`.
///
/// Namespace-insensitive: it keys off the local element name (`href`,
/// `getcontenttype`, …) so it doesn't matter whether the server prefixes with
/// `d:` / `D:` / something else. `XMLParser` ignores DTDs by default, so this is
/// not exposed to XXE.
///
/// Parsing rules (API Contract §7):
/// - skip the collection response whose path equals the requested folder
///   (`selfSegments`); `nil` keeps every file entry (used for `Depth: 0` stat calls)
/// - skip sub-folders (`<resourcetype>` contains `<collection/>`)
/// - a "404" propstat carries empty self-closing prop elements → treat missing
///   values as unknown, don't drop the entry
/// - hrefs may be a path or an absolute URL; they are reduced to a server-relative
///   path and the display name is the decoded last segment
/// - sort newest first
final class PropfindParser: NSObject, XMLParserDelegate {
    /// Position of an XML failure — the parser's message can quote the document, so
    /// only this is ever forwarded to diagnostics.
    struct ParseFailure: Error {
        let line: Int
        let column: Int
    }

    private let selfSegments: [String]?
    private var items: [RemoteItem] = []

    private var text = ""

    private var href: String?
    private var isDir = false
    private var contentType = ""
    private var size: Int64 = 0
    private var lastModified = Date(timeIntervalSince1970: 0)
    private var fileID: String?
    private var hasPreview = false
    private var uploadedAt: Date?

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    init(selfSegments: [String]?) {
        self.selfSegments = selfSegments
    }

    func parse(_ data: Data) throws -> [RemoteItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw ParseFailure(line: parser.lineNumber, column: parser.columnNumber)
        }
        return items.sorted { $0.lastModified > $1.lastModified }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        text = ""
        switch localName(elementName) {
        case "response":
            href = nil; isDir = false; contentType = ""; size = 0
            lastModified = Date(timeIntervalSince1970: 0); fileID = nil; hasPreview = false
            uploadedAt = nil
        case "collection":
            isDir = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href": if !value.isEmpty { href = value }
        case "getcontenttype": contentType = value
        case "getcontentlength": size = Int64(value) ?? 0
        case "getlastmodified":
            if let date = Self.httpDateFormatter.date(from: value) { lastModified = date }
        case "fileid": if !value.isEmpty { fileID = value }
        case "upload_time":
            if let seconds = TimeInterval(value), seconds > 0 { uploadedAt = Date(timeIntervalSince1970: seconds) }
        case "has-preview": hasPreview = value.caseInsensitiveCompare("true") == .orderedSame
        case "response": collectResponse()
        default:
            break
        }
        text = ""
    }

    /// On a `</d:response>`, turns the accumulated entry into a `RemoteItem` if it's a file.
    private func collectResponse() {
        guard let href else { return }
        let segments = hrefSegments(href)
        if isDir || (selfSegments != nil && segments == selfSegments) { return }
        items.append(RemoteItem(
            href: hrefPath(href),
            // Decoded as a path segment: `+` is literal, `%2B` / `%20` decode as expected.
            name: segments.last ?? "",
            isDirectory: false,
            contentType: contentType,
            sizeBytes: size,
            lastModified: lastModified,
            fileID: fileID,
            hasPreview: hasPreview,
            uploadedAt: uploadedAt
        ))
    }

    private func localName(_ raw: String) -> String {
        (raw.split(separator: ":").last.map(String.init) ?? raw).lowercased()
    }
}
