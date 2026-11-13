import Foundation

/// A `pbbp2.Frame` — the protobuf envelope used by the long-connection gateway.
///
/// ```proto
/// message Header { required string key = 1; required string value = 2; }
/// message Frame {
///   required uint64 SeqID = 1;  required uint64 LogID = 2;
///   required int32 service = 3; required int32 method = 4;
///   repeated Header headers = 5;
///   optional string payload_encoding = 6; optional string payload_type = 7;
///   optional bytes payload = 8; optional string LogIDNew = 9;
/// }
/// ```
public struct WSFrame: Sendable, Hashable {
    public struct Header: Sendable, Hashable {
        public var key: String
        public var value: String
        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var seqID: UInt64
    public var logID: UInt64
    public var service: Int32
    public var method: Int32
    public var headers: [Header]
    public var payloadEncoding: String?
    public var payloadType: String?
    public var payload: Data?
    public var logIDNew: String?

    public init(
        seqID: UInt64 = 0, logID: UInt64 = 0, service: Int32 = 0, method: Int32 = 0, headers: [Header] = [],
        payloadEncoding: String? = nil, payloadType: String? = nil, payload: Data? = nil, logIDNew: String? = nil
    ) {
        self.seqID = seqID
        self.logID = logID
        self.service = service
        self.method = method
        self.headers = headers
        self.payloadEncoding = payloadEncoding
        self.payloadType = payloadType
        self.payload = payload
        self.logIDNew = logIDNew
    }

    /// First header value for `key`.
    public func header(_ key: String) -> String? { headers.first { $0.key == key }?.value }

    // MARK: Encoding

    public func serialized() -> Data {
        var w = ProtoWriter()
        w.varintField(1, seqID)
        w.varintField(2, logID)
        w.varintField(3, UInt64(bitPattern: Int64(service)))
        w.varintField(4, UInt64(bitPattern: Int64(method)))
        for h in headers {
            var hw = ProtoWriter()
            hw.bytesField(1, Data(h.key.utf8))
            hw.bytesField(2, Data(h.value.utf8))
            w.bytesField(5, hw.data)
        }
        if let v = payloadEncoding { w.bytesField(6, Data(v.utf8)) }
        if let v = payloadType { w.bytesField(7, Data(v.utf8)) }
        if let v = payload { w.bytesField(8, v) }
        if let v = logIDNew { w.bytesField(9, Data(v.utf8)) }
        return w.data
    }

    // MARK: Decoding

    public init(serializedData data: Data) throws {
        self.init()
        var r = ProtoReader(data)
        while let (field, wire) = try r.nextTag() {
            switch (field, wire) {
            case (1, 0): seqID = try r.varint()
            case (2, 0): logID = try r.varint()
            case (3, 0): service = Int32(truncatingIfNeeded: try r.varint())
            case (4, 0): method = Int32(truncatingIfNeeded: try r.varint())
            case (5, 2):
                var hr = ProtoReader(try r.lengthDelimited())
                var h = Header(key: "", value: "")
                while let (hf, hwire) = try hr.nextTag() {
                    switch (hf, hwire) {
                    case (1, 2): h.key = String(decoding: try hr.lengthDelimited(), as: UTF8.self)
                    case (2, 2): h.value = String(decoding: try hr.lengthDelimited(), as: UTF8.self)
                    default: try hr.skip(wire: hwire)
                    }
                }
                headers.append(h)
            case (6, 2): payloadEncoding = String(decoding: try r.lengthDelimited(), as: UTF8.self)
            case (7, 2): payloadType = String(decoding: try r.lengthDelimited(), as: UTF8.self)
            case (8, 2): payload = try r.lengthDelimited()
            case (9, 2): logIDNew = String(decoding: try r.lengthDelimited(), as: UTF8.self)
            default: try r.skip(wire: wire)
            }
        }
    }
}

/// Errors raised while decoding protobuf data.
public struct ProtobufDecodingError: Error, Sendable, CustomStringConvertible {
    public let description: String
}

struct ProtoWriter {
    var data = Data()

    mutating func rawVarint(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func tag(_ field: Int, _ wire: Int) { rawVarint(UInt64(field << 3 | wire)) }

    mutating func varintField(_ field: Int, _ v: UInt64) {
        tag(field, 0)
        rawVarint(v)
    }

    mutating func bytesField(_ field: Int, _ bytes: Data) {
        tag(field, 2)
        rawVarint(UInt64(bytes.count))
        data.append(bytes)
    }
}

struct ProtoReader {
    let bytes: [UInt8]
    var pos = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var atEnd: Bool { pos >= bytes.count }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard pos < bytes.count else { throw ProtobufDecodingError(description: "truncated varint") }
            let b = bytes[pos]
            pos += 1
            if shift < 64 { result |= UInt64(b & 0x7F) << shift }
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 70 { throw ProtobufDecodingError(description: "malformed varint") }
        }
    }

    mutating func nextTag() throws -> (Int, Int)? {
        if atEnd { return nil }
        let t = try varint()
        let field = Int(t >> 3)
        guard field > 0 else { throw ProtobufDecodingError(description: "invalid field number 0") }
        return (field, Int(t & 7))
    }

    mutating func lengthDelimited() throws -> Data {
        let len = try varint()
        guard len <= UInt64(bytes.count - pos) else { throw ProtobufDecodingError(description: "truncated bytes field") }
        let n = Int(len)
        defer { pos += n }
        return Data(bytes[pos..<pos + n])
    }

    mutating func skip(wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: try advance(8)
        case 2: _ = try lengthDelimited()
        case 5: try advance(4)
        default: throw ProtobufDecodingError(description: "unsupported wire type \(wire)")
        }
    }

    private mutating func advance(_ n: Int) throws {
        guard pos + n <= bytes.count else { throw ProtobufDecodingError(description: "truncated fixed field") }
        pos += n
    }
}
