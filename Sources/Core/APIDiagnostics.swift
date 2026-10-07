import Foundation

/// Builds crash-report context for an unexpected server response **without content**.
///
/// Decoder error messages can embed the offending input, so they are never forwarded.
/// What *is* useful for diagnosing server API drift is the shape: HTTP status, content
/// type, size, and the field *names* present — e.g. `json{ocs{data[3]{id,item_type,...},meta{...}}}` —
/// which shows a key was renamed or an HTML error page came back, without a single value
/// (no paths, names or ids).
enum APIDiagnostics {
    private static let maxDepth = 4
    private static let maxKeys = 24
    private static let maxShapeChars = 400

    static func describe(status: Int, contentType: String?, body: Data?, failure: Error) -> String {
        var parts = [
            "status=\(status)",
            "ct=\(mimeType(contentType))",
            "len=\(body?.count ?? -1)",
            "error=\(String(describing: type(of: failure)))",
        ]
        if let body { parts.append("shape=\(shapeOf(body))") }
        return parts.joined(separator: " ")
    }

    /// Position-only description for XML failures (the parser message quotes the document).
    static func describeXML(status: Int, contentType: String?, line: Int, column: Int) -> String {
        "status=\(status) ct=\(mimeType(contentType)) error=XMLParseError at=\(line):\(column)"
    }

    static func shapeOf(_ body: Data) -> String {
        let text = String(bytes: body.prefix(64 * 1024), encoding: .utf8) ?? ""
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shape: String = if text.isEmpty {
            "empty"
        } else if text.hasPrefix("<") {
            text.lowercased().hasPrefix("<!doctype html") || text.lowercased().hasPrefix("<html")
                ? "html" : "xml"
        } else if text.hasPrefix("{") || text.hasPrefix("[") {
            jsonShape(body)
        } else {
            "text"
        }
        return String(shape.prefix(maxShapeChars))
    }

    private static func mimeType(_ contentType: String?) -> String {
        guard let head = contentType?.split(separator: ";").first else { return "none" }
        return String(head.trimmingCharacters(in: .whitespaces).prefix(64))
    }

    private static func jsonShape(_ body: Data) -> String {
        guard let node = try? JSONSerialization.jsonObject(with: body) else { return "json-invalid" }
        return "json" + shape(of: node, depth: 0)
    }

    private static func shape(of node: Any, depth: Int) -> String {
        if let object = node as? [String: Any] {
            return depth >= maxDepth ? "{…}" : objectShape(object, depth: depth)
        }
        if let array = node as? [Any] {
            var result = "[\(array.count)]"
            if let first = array.first, depth < maxDepth {
                let inner = shape(of: first, depth: depth + 1)
                if inner.hasPrefix("{") { result += inner }
            }
            return result
        }
        return ""
    }

    private static func objectShape(_ object: [String: Any], depth: Int) -> String {
        let body = object.keys.sorted().prefix(maxKeys).map { key -> String in
            let inner = object[key].map { shape(of: $0, depth: depth + 1) } ?? ""
            return key + (inner.hasPrefix("{") || inner.hasPrefix("[") ? inner : "")
        }
        return "{" + body.joined(separator: ",") + "}"
    }
}
