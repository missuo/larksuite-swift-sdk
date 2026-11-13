import Foundation
#if canImport(zlib)
import zlib
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Minimal gzip writer equivalent to Node's `zlib.gzipSync(buffer)` with default options
/// (level 6, `windowBits` 15, `memLevel` 8, default strategy, `mtime` 0).
///
/// The deflate stream comes from the platform's zlib, which is the same library Node bundles,
/// so the output is byte-for-byte what node-sdk produces on the same OS:
///
/// - Apple platforms: zlib is linked directly (`import zlib`).
/// - Linux: zlib is loaded at runtime (`libz.so.1`) because SwiftPM offers no zlib module there
///   and this package may not add a system-library target.
/// - If zlib cannot be loaded at all, the payload is wrapped in *stored* (uncompressed) deflate
///   blocks. That is still a valid gzip stream that decodes to the same bytes, only longer.
enum Gzip {
    /// Backend that produces the raw deflate stream.
    enum Backend: Sendable {
        #if canImport(zlib)
        /// The zlib linked into the process.
        case linked
        #endif
        /// zlib loaded with `dlopen`.
        case dynamic(DynamicZlib)
        /// Stored (uncompressed) deflate blocks.
        case stored
    }

    /// Node's default compression level (`Z_DEFAULT_COMPRESSION` → 6).
    static let level: Int32 = 6

    /// The gzip header `OS` byte zlib writes (`OS_CODE` in zlib's `zutil.h`).
    static var osCode: UInt8 {
        #if canImport(Darwin)
        return 19
        #elseif os(Windows)
        return 10
        #else
        return 3
        #endif
    }

    /// The backend used by default on this platform.
    static let defaultBackend: Backend = {
        #if canImport(zlib)
        return .linked
        #else
        if let lib = DynamicZlib.load(paths: ["libz.so.1", "libz.so"]) { return .dynamic(lib) }
        return .stored
        #endif
    }()

    /// Gzips `input` the way `zlib.gzipSync(input)` does.
    static func compress(_ input: [UInt8], backend: Backend = defaultBackend) -> [UInt8] {
        let deflated = rawDeflate(input, backend: backend) ?? storedDeflate(input)
        // Header: magic, CM=deflate, FLG=0, MTIME=0, XFL=0 (level 6), OS.
        var out: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, osCode]
        out.reserveCapacity(out.count + deflated.count + 8)
        out += deflated
        appendLE32(&out, crc32(input))
        appendLE32(&out, UInt32(truncatingIfNeeded: input.count))
        return out
    }

    // MARK: - Deflate backends

    /// Raw deflate stream (no zlib/gzip wrapper), or `nil` if the backend failed.
    static func rawDeflate(_ input: [UInt8], backend: Backend) -> [UInt8]? {
        switch backend {
        #if canImport(zlib)
        case .linked:
            return zlibWrapped(input) { dest, destLen, src, srcLen, lvl in
                compress2(dest, destLen, src, srcLen, lvl)
            } bound: { compressBound($0) }.flatMap(stripZlibWrapper)
        #endif
        case .dynamic(let lib):
            return zlibWrapped(input) { dest, destLen, src, srcLen, lvl in
                lib.compress2(dest, destLen, src, srcLen, lvl)
            } bound: { lib.compressBound($0) }.flatMap(stripZlibWrapper)
        case .stored:
            return storedDeflate(input)
        }
    }

    /// Runs zlib's `compress2` (zlib format: 2-byte header + deflate + Adler-32).
    ///
    /// `compress2` uses `deflateInit(level)`, i.e. `windowBits` 15 / `memLevel` 8 / default
    /// strategy: exactly the parameters of Node's `gzipSync`, so the deflate payload is identical.
    private static func zlibWrapped(
        _ input: [UInt8],
        compress: (UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt>?, UnsafePointer<UInt8>?, UInt, Int32) -> Int32,
        bound: (UInt) -> UInt
    ) -> [UInt8]? {
        var destLen = bound(UInt(input.count))
        var dest = [UInt8](repeating: 0, count: Int(destLen))
        let status = input.withUnsafeBufferPointer { src in
            dest.withUnsafeMutableBufferPointer { dst in
                compress(dst.baseAddress, &destLen, src.baseAddress, UInt(src.count), level)
            }
        }
        guard status == 0 /* Z_OK */ else { return nil }
        return Array(dest.prefix(Int(destLen)))
    }

    private static func stripZlibWrapper(_ wrapped: [UInt8]) -> [UInt8]? {
        // CMF/FLG header without a preset dictionary, and the 4-byte Adler-32 trailer.
        guard wrapped.count >= 6, wrapped[1] & 0x20 == 0 else { return nil }
        return Array(wrapped[2..<(wrapped.count - 4)])
    }

    /// Deflate stream made of stored blocks (RFC 1951 §3.2.4).
    static func storedDeflate(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count + (input.count / 65_535 + 1) * 5)
        var offset = 0
        repeat {
            let length = min(65_535, input.count - offset)
            let isFinal = offset + length >= input.count
            out.append(isFinal ? 0x01 : 0x00)
            let len = UInt16(length)
            out += [UInt8(len & 0xff), UInt8(len >> 8), UInt8(~len & 0xff), UInt8(~len >> 8)]
            out += input[offset..<(offset + length)]
            offset += length
        } while offset < input.count
        return out
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func appendLE32(_ out: inout [UInt8], _ v: UInt32) {
        out += [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]
    }
}

/// zlib's `compress2` / `compressBound` resolved with `dlopen` / `dlsym`.
struct DynamicZlib: Sendable {
    typealias Compress2 = @convention(c) (
        UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt>?, UnsafePointer<UInt8>?, UInt, Int32
    ) -> Int32
    typealias CompressBound = @convention(c) (UInt) -> UInt

    let compress2: Compress2
    let compressBound: CompressBound

    /// Loads the first library in `paths` that exports both symbols. The handle is never closed.
    static func load(paths: [String]) -> DynamicZlib? {
        #if canImport(Darwin) || canImport(Glibc)
        for path in paths {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            guard let c = dlsym(handle, "compress2"), let b = dlsym(handle, "compressBound") else {
                dlclose(handle)
                continue
            }
            return DynamicZlib(
                compress2: unsafeBitCast(c, to: Compress2.self),
                compressBound: unsafeBitCast(b, to: CompressBound.self))
        }
        #endif
        return nil
    }
}
