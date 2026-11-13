import Foundation

/// A file to upload in a multipart request.
public struct LarkFile: Sendable, Hashable {
    public var data: Data
    public var fileName: String
    public var contentType: String

    public init(data: Data, fileName: String = "file", contentType: String = "application/octet-stream") {
        self.data = data
        self.fileName = fileName
        self.contentType = contentType
    }

    /// Reads a file from disk.
    public init(contentsOf url: URL, fileName: String? = nil, contentType: String? = nil) throws {
        self.data = try Data(contentsOf: url)
        self.fileName = fileName ?? url.lastPathComponent
        self.contentType = contentType ?? LarkFile.guessContentType(url.pathExtension)
    }

    /// Reads a file from a path on disk.
    public init(path: String, fileName: String? = nil, contentType: String? = nil) throws {
        try self.init(contentsOf: URL(fileURLWithPath: path), fileName: fileName, contentType: contentType)
    }

    static func guessContentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "mp4": return "video/mp4"
        case "opus", "ogg": return "audio/ogg"
        case "txt": return "text/plain"
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: return "application/octet-stream"
        }
    }
}

extension LarkFile: Codable {
    // Files are never serialised as JSON; this conformance only exists so that
    // generated multipart bodies can share the `Codable` model protocol.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        self.init(data: Data(base64Encoded: s) ?? Data(s.utf8))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(data.base64EncodedString())
    }
}

/// A `multipart/form-data` body.
public struct MultipartForm: Sendable {
    public enum Part: Sendable {
        case field(name: String, value: String)
        case file(name: String, file: LarkFile)
    }

    public var parts: [Part]
    public var boundary: String

    public init(parts: [Part] = [], boundary: String = "LarkFormBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))") {
        self.parts = parts
        self.boundary = boundary
    }

    public mutating func append(_ name: String, _ value: String?) {
        if let value { parts.append(.field(name: name, value: value)) }
    }

    public mutating func append(_ name: String, _ value: Int?) { append(name, value.map { String($0) }) }
    public mutating func append(_ name: String, _ value: Double?) { append(name, value.map { JSONValue.formatNumber($0) }) }
    public mutating func append(_ name: String, _ value: Bool?) { append(name, value.map { $0 ? "true" : "false" }) }
    public mutating func append<E: LarkOpenEnum>(_ name: String, _ value: E?) { append(name, value?.rawValue) }
    public mutating func append(_ name: String, _ file: LarkFile?) {
        if let file { parts.append(.file(name: name, file: file)) }
    }
    /// Appends any other encodable value as JSON text.
    public mutating func append<T: Encodable>(_ name: String, json value: T?) {
        guard let value, let s = try? LarkJSON.string(value) else { return }
        parts.append(.field(name: name, value: s))
    }

    public func encode() -> (body: Data, contentType: String) {
        var body = Data()
        func w(_ s: String) { body.append(Data(s.utf8)) }
        for part in parts {
            w("--\(boundary)\r\n")
            switch part {
            case .field(let name, let value):
                w("Content-Disposition: form-data; name=\"\(escape(name))\"\r\n\r\n")
                w(value)
            case .file(let name, let file):
                w("Content-Disposition: form-data; name=\"\(escape(name))\"; filename=\"\(escape(file.fileName))\"\r\n")
                w("Content-Type: \(file.contentType)\r\n\r\n")
                body.append(file.data)
            }
            w("\r\n")
        }
        w("--\(boundary)--\r\n")
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}

/// Generated request bodies for upload APIs conform to this protocol.
public protocol LarkMultipartBody: Sendable {
    func multipartForm() -> MultipartForm
}
