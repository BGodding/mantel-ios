import Foundation

/// Streams a WebDAV `PROPFIND` `multistatus` body into `[RemoteItem]`.
///
/// Namespace-insensitive: it keys off the local element name (`href`,
/// `getcontenttype`, …) so it doesn't matter whether the server prefixes with
/// `d:` / `D:` / something else. `XMLParser` ignores DTDs by default, so this is
/// not exposed to XXE.
///
/// Parsing rules (API Contract §7):
/// - skip the collection response whose href equals the requested folder
/// - skip sub-folders (`<resourcetype>` contains `<collection/>`)
/// - a "404" propstat carries empty self-closing prop elements → treat missing
///   values as unknown, don't drop the entry
/// - sort newest first
final class PropfindParser: NSObject, XMLParserDelegate {
    private let selfPath: String
    private var items: [RemoteItem] = []

    private var currentElement = ""
    private var text = ""

    private var href: String?
    private var isDir = false
    private var contentType = ""
    private var size: Int64 = 0
    private var lastModified = Date(timeIntervalSince1970: 0)
    private var fileID: String?
    private var hasPreview = false

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    init(selfPath: String) {
        self.selfPath = selfPath
    }

    func parse(_ data: Data) -> [RemoteItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return items.sorted { $0.lastModified > $1.lastModified }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        currentElement = localName(elementName)
        text = ""
        switch currentElement {
        case "response":
            href = nil; isDir = false; contentType = ""; size = 0
            lastModified = Date(timeIntervalSince1970: 0); fileID = nil; hasPreview = false
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
        case "has-preview": hasPreview = value.caseInsensitiveCompare("true") == .orderedSame
        case "response":
            if let href, !isDir, !samePath(href, selfPath) {
                items.append(RemoteItem(
                    href: href,
                    name: decodeName(href),
                    isDirectory: false,
                    contentType: contentType,
                    sizeBytes: size,
                    lastModified: lastModified,
                    fileID: fileID,
                    hasPreview: hasPreview
                ))
            }
        default:
            break
        }
        text = ""
    }

    private func localName(_ raw: String) -> String {
        (raw.split(separator: ":").last.map(String.init) ?? raw).lowercased()
    }

    private func samePath(_ lhs: String, _ rhs: String) -> Bool {
        func normalise(_ value: String) -> String {
            var path = value
            if let range = path.range(of: "://") {
                path = String(path[range.upperBound...])
                if let slash = path.firstIndex(of: "/") { path = String(path[slash...]) }
            }
            return path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return normalise(lhs) == normalise(rhs)
    }

    private func decodeName(_ href: String) -> String {
        let last = href.hasSuffix("/") ? String(href.dropLast()) : href
        let segment = last.split(separator: "/").last.map(String.init) ?? last
        return segment.removingPercentEncoding ?? segment
    }
}
