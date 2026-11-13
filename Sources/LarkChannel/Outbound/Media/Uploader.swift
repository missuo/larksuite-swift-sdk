import Foundation
import LarkCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Port of node-sdk `media/uploader.ts`: turns a ``MediaSource`` into bytes
/// (SSRF-guarded URL fetch or LFI-guarded local read) and uploads it.
///
/// Deviations: the URL fetch goes through the client's ``LarkHTTPClient``
/// (GET, 15 s timeout) and the 50 MB cap is checked after the body is
/// received (node aborts mid-stream via axios `maxContentLength`); the fetch
/// is not pinned to the validated IP (see ``SSRFGuard``); multipart file parts
/// carry a `filename` (`image` / the file name), which node's form-data omits.
struct MediaUploader: Sendable {
    enum Kind: String, Sendable { case image, file, audio, video }

    struct Input: Sendable {
        var kind: Kind
        var source: MediaSource
        var fileName: String?
        /// Explicit duration in ms.
        var duration: Int?
    }

    struct Result: Sendable, Equatable {
        var kind: Kind
        /// `image_key` for images, `file_key` otherwise.
        var fileKey: String
        var durationMs: Int?
    }

    /// POSIX prefixes that can never be a legitimate media source.
    static let posixBlockedPrefixes = ["/etc/", "/proc/", "/sys/", "/dev/"]
    /// Max bytes accepted from a URL source.
    static let urlMaxBytes = 50 * 1024 * 1024
    /// URL fetch timeout (node: 15 000 ms).
    static let urlTimeout: TimeInterval = 15

    let api: ChannelAPI
    let config: OutboundConfig

    func upload(_ input: Input) async throws -> Result {
        let buffer = try await toBuffer(input.source)
        switch input.kind {
        case .image:
            return try await uploadImage(buffer)
        case .audio:
            let d = try resolveDuration(input, buffer)
            return try await uploadFile(buffer, fileType: "opus", fileName: input.fileName ?? "voice.opus", durationMs: d)
        case .video:
            let d = try resolveDuration(input, buffer)
            return try await uploadFile(buffer, fileType: "mp4", fileName: input.fileName ?? "video.mp4", durationMs: d)
        case .file:
            return try await uploadFile(buffer, fileType: "stream", fileName: input.fileName ?? "upload.bin", durationMs: nil)
        }
    }

    // MARK: Source resolution

    private static let urlPattern = JS.regex("\\A[hH][tT][tT][pP][sS]?://")

    func toBuffer(_ source: MediaSource) async throws -> Data {
        let s: String
        switch source {
        case .data(let d): return d
        case .location(let loc): s = loc
        }

        if !JS.test(Self.urlPattern, s) {
            let resolved = Self.resolvePath(s)
            try Self.assertNotOnPosixBlocklist(resolved)
            do {
                let real = try Self.realpath(resolved)
                try Self.assertNotOnPosixBlocklist(real)
                if let dirs = config.allowedFileDirs, !dirs.isEmpty {
                    let canonical = dirs.map { d -> String in
                        let r = Self.resolvePath(d)
                        return (try? Self.realpath(r)) ?? r
                    }
                    let inAllowed = canonical.contains { real == $0 || real.hasPrefix($0 + "/") }
                    if !inAllowed {
                        throw LarkChannelError(.uploadFailed, "file path is outside allowed directories: \(real)")
                    }
                }
                return try Data(contentsOf: URL(fileURLWithPath: real))
            } catch let e as LarkChannelError {
                throw e
            } catch {
                throw LarkChannelError(
                    .uploadFailed, "source is neither an http(s) URL nor a readable local file: \(s)", cause: error)
            }
        }

        let guardEnabled: Bool
        var allowlist: [String]?
        switch config.ssrfGuard ?? .enabled {
        case .disabled: guardEnabled = false
        case .enabled: guardEnabled = true
        case .allowlist(let list):
            guardEnabled = true
            allowlist = list
        }
        if guardEnabled {
            do {
                _ = try await SSRFGuard.assertPublicURL(s, allowlist: allowlist, resolver: config.hostResolver ?? SystemHostResolver())
            } catch {
                throw LarkChannelError(.ssrfBlocked, "URL blocked: \(Self.errorString(error))", cause: error)
            }
        }
        do {
            guard let url = URL(string: s) else { throw LarkError.invalidArgument("invalid url: \(s)") }
            let resp = try await api.client.config.httpClient.send(
                LarkHTTPRequest(method: .get, url: url, headers: [:], body: nil, timeout: Self.urlTimeout))
            guard (200..<300).contains(resp.statusCode) else {
                throw LarkError.http(statusCode: resp.statusCode, headers: resp.headers, body: resp.body)
            }
            if resp.body.count > Self.urlMaxBytes {
                throw LarkError.transport(message: "maxContentLength size of \(Self.urlMaxBytes) exceeded")
            }
            return resp.body
        } catch {
            throw LarkChannelError(.uploadFailed, "fetch source URL failed", cause: error)
        }
    }

    /// `String(e)` for an `Error` (`Error: message`).
    static func errorString(_ e: any Error) -> String {
        if let s = e as? SSRFBlockedError { return s.description }
        return "Error: \(e)"
    }

    /// `path.resolve(p)`: absolute against the current directory, `.`/`..` collapsed.
    static func resolvePath(_ p: String) -> String {
        let absolute = p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
        var parts: [Substring] = []
        for comp in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(comp)
        }
        return "/" + parts.joined(separator: "/")
    }

    struct RealpathError: Error, CustomStringConvertible {
        var path: String
        var errno: Int32
        var description: String { "ENOENT: no such file or directory, realpath '\(path)' (errno \(errno))" }
    }

    /// `fs.promises.realpath`.
    static func realpath(_ p: String) throws -> String {
        guard let r = cRealpath(p) else { throw RealpathError(path: p, errno: errno) }
        return r
    }

    private static func cRealpath(_ p: String) -> String? {
        guard let ptr = ChannelLibc.realpath(p, nil) else { return nil }
        defer { free(ptr) }
        return String(cString: ptr)
    }

    /// Rejects `/etc`, `/proc`, `/sys`, `/dev` (checked before and after realpath).
    static func assertNotOnPosixBlocklist(_ p: String) throws {
        #if os(Windows)
        return
        #else
        if posixBlockedPrefixes.contains(where: { p == String($0.dropLast()) || p.hasPrefix($0) }) {
            throw LarkChannelError(.uploadFailed, "file path is not allowed: \(p)")
        }
        #endif
    }

    // MARK: Duration

    func resolveDuration(_ input: Input, _ buffer: Data) throws -> Int {
        if let d = input.duration, d > 0 { return d }
        let parsed: Int?
        switch input.kind {
        case .audio: parsed = MediaDuration.parseOpusDuration(buffer)
        case .video: parsed = MediaDuration.parseMp4Duration(buffer)
        default: parsed = nil
        }
        if let parsed { return parsed }
        throw LarkChannelError(.uploadFailed, "duration could not be determined for \(input.kind.rawValue); pass it explicitly")
    }

    // MARK: Upload

    func uploadImage(_ buffer: Data) async throws -> Result {
        do {
            let r = try await api.imageCreate(buffer)
            guard let key = r.data?["image_key"]?.stringValue ?? r.json?["image_key"]?.stringValue, !key.isEmpty else {
                throw LarkError.invalidArgument("image_key missing in upload response")
            }
            return Result(kind: .image, fileKey: key)
        } catch {
            throw LarkChannelError(.uploadFailed, "image upload failed", cause: error)
        }
    }

    func uploadFile(_ buffer: Data, fileType: String, fileName: String, durationMs: Int?) async throws -> Result {
        do {
            let r = try await api.fileCreate(fileType: fileType, fileName: fileName, data: buffer, duration: durationMs)
            guard let key = r.data?["file_key"]?.stringValue ?? r.json?["file_key"]?.stringValue, !key.isEmpty else {
                throw LarkError.invalidArgument("file_key missing in upload response")
            }
            let kind: Kind = fileType == "opus" ? .audio : fileType == "mp4" ? .video : .file
            return Result(kind: kind, fileKey: key, durationMs: durationMs)
        } catch let e as LarkChannelError {
            throw e
        } catch {
            throw LarkChannelError(.uploadFailed, "file upload failed", cause: error)
        }
    }
}

/// Namespaced libc access (avoids clashing with the `realpath` helper above).
enum ChannelLibc {
    static func realpath(_ path: String, _ resolved: UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
        #if canImport(Darwin)
        return Darwin.realpath(path, resolved)
        #elseif canImport(Glibc)
        return Glibc.realpath(path, resolved)
        #elseif canImport(Musl)
        return Musl.realpath(path, resolved)
        #else
        return nil
        #endif
    }
}
