import Foundation
import Testing
@testable import LarkChannel
@testable import LarkCore

/// Ports of node-sdk `outbound/__tests__/{duration-ogg,duration-mp4,ssrf-guard,uploader}.test.ts`
/// plus node-produced vectors.
@Suite struct MediaTests {
    static func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    // MARK: duration-ogg.test.ts

    /// Minimal Ogg page (27-byte header) with a granule position, as built by the node test.
    static func oggPage(_ granule: Int64) -> Data {
        var b = Data("OggS".utf8)
        b.append(contentsOf: [0, 0])
        withUnsafeBytes(of: granule.littleEndian) { b.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(1).littleEndian) { b.append(contentsOf: $0) }
        b.append(Data(count: 9))
        return b
    }

    @Test func opusDuration() {
        #expect(MediaDuration.parseOpusDuration(Data()) == nil)
        #expect(MediaDuration.parseOpusDuration(Data(count: 10)) == nil)
        #expect(MediaDuration.parseOpusDuration(Self.oggPage(48_000)) == 1000)
        #expect(MediaDuration.parseOpusDuration(Self.oggPage(72_000)) == 1500)
        #expect(MediaDuration.parseOpusDuration(Self.oggPage(24_000) + Self.oggPage(96_000)) == 2000)
        #expect(MediaDuration.parseOpusDuration(Self.oggPage(-1)) == nil)
        #expect(MediaDuration.parseOpusDuration(Data("not an ogg file here at all at all".utf8)) == nil)
    }

    // MARK: duration-mp4.test.ts

    static func box(_ type: String, _ payload: Data) -> Data {
        var b = Data()
        withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { b.append(contentsOf: $0) }
        b.append(Data(type.utf8))
        b.append(payload)
        return b
    }

    static func mp4(timescale: UInt32, duration: UInt32) -> Data {
        var p = Data(count: 100)
        p.replaceSubrange(12..<16, with: withUnsafeBytes(of: timescale.bigEndian) { Data($0) })
        p.replaceSubrange(16..<20, with: withUnsafeBytes(of: duration.bigEndian) { Data($0) })
        return box("moov", box("mvhd", p))
    }

    @Test func mp4Duration() {
        #expect(MediaDuration.parseMp4Duration(Data()) == nil)
        #expect(MediaDuration.parseMp4Duration(Self.mp4(timescale: 1000, duration: 30_000)) == 30_000)
        #expect(MediaDuration.parseMp4Duration(Self.mp4(timescale: 600, duration: 3600)) == 6000)
        var noMoov = Data(count: 100)
        noMoov.replaceSubrange(4..<8, with: Data("mdat".utf8))
        #expect(MediaDuration.parseMp4Duration(noMoov) == nil)
        #expect(MediaDuration.parseMp4Duration(Self.mp4(timescale: 0, duration: 10)) == nil)
        #expect(MediaDuration.parseMp4Duration(Data("this is not an mp4 file at all really nothing to see here".utf8)) == nil)
    }

    /// Byte vectors built by node (`Buffer` writes; ogg pages, mp4 v0/v1 `mvhd`,
    /// 64-bit `largesize`, size-0 boxes, nested/preceding boxes) and the
    /// durations node-sdk parsed from them.
    @Test func durationsMatchNodeVectors() {
        for p in Vectors["ogg"].array {
            #expect(MediaDuration.parseOpusDuration(Self.hex(p[0]!.string!)) == p[1]?.intValue)
        }
        for p in Vectors["mp4"].array {
            #expect(MediaDuration.parseMp4Duration(Self.hex(p[0]!.string!)) == p[1]?.intValue, "\(p[0]!)")
        }
    }

    // MARK: ssrf-guard.test.ts

    static func check(_ url: String, _ records: [ResolvedAddress] = [], allowlist: [String]? = nil) async throws -> SSRFGuard.Validation {
        try await SSRFGuard.assertPublicURL(url, allowlist: allowlist, resolver: StubResolver(records: records))
    }

    static func expectBlocked(_ url: String, _ records: [ResolvedAddress] = []) async {
        do {
            _ = try await check(url, records)
            Issue.record("expected \(url) to be blocked")
        } catch let e as SSRFBlockedError {
            #expect(e.message.hasPrefix("ssrf_blocked"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    static func v4(_ a: String) -> ResolvedAddress { ResolvedAddress(address: a, family: 4) }
    static func v6(_ a: String) -> ResolvedAddress { ResolvedAddress(address: a, family: 6) }

    @Test func ssrfPublicHostnamePins() async throws {
        #expect(try await Self.check("https://example.com/x", [Self.v4("8.8.8.8")]) == .init(resolvedIp: "8.8.8.8", originalHost: "example.com"))
        await Self.expectBlocked("http://evil.com/", [Self.v4("169.254.169.254")])
        await Self.expectBlocked("http://evil.com/", [Self.v4("8.8.8.8"), Self.v4("169.254.169.254")])
    }

    @Test func ssrfIpLiteralSkipsDns() async throws {
        let resolver = StubResolver(records: [])
        let r = try await SSRFGuard.assertPublicURL("http://1.2.3.4/", resolver: resolver)
        #expect(r.resolvedIp == "1.2.3.4")
        #expect(resolver.calls.count == 0)
        await Self.expectBlocked("http://169.254.169.254/")
        await Self.expectBlocked("http://[::1]/")
    }

    @Test func ssrfIPv6BypassVectors() async throws {
        await Self.expectBlocked("http://[::ffff:127.0.0.1]/")
        await Self.expectBlocked("http://expanded.test/", [Self.v6("0:0:0:0:0:ffff:7f00:1")])
        await Self.expectBlocked("http://v4compat.test/", [Self.v6("::7f00:1")])
        await Self.expectBlocked("http://nat64.test/", [Self.v6("64:ff9b::a00:1")])
        #expect(try await Self.check("http://nat64pub.test/", [Self.v6("64:ff9b::808:808")]).resolvedIp == "64:ff9b::808:808")
        await Self.expectBlocked("http://doc.test/", [Self.v6("2001:db8::1")])
        await Self.expectBlocked("http://teredo.test/", [Self.v6("2001:0:1234::1")])
        #expect(try await Self.check("http://dns.test/", [Self.v6("2001:4860:4860::8888")]).resolvedIp == "2001:4860:4860::8888")
        await Self.expectBlocked("http://ll.test/", [Self.v6("fe80::1%eth0")])
        await Self.expectBlocked("http://ula-fc.test/", [Self.v6("fc12:3456::1")])
        await Self.expectBlocked("http://ula-fd.test/", [Self.v6("fd00:abcd::1")])
        await Self.expectBlocked("http://expanded-lo.test/", [Self.v6("0:0:0:0:0:0:0:1")])
        await Self.expectBlocked("http://garbage.test/", [Self.v6("not::an::ipv6")])
    }

    @Test func ssrfProtocolsDnsAllowlistCgnatAndPinning() async throws {
        await Self.expectBlocked("file:///etc/passwd")
        await Self.expectBlocked("gopher://evil.com/")
        await Self.expectBlocked("http://nxdomain.invalid/", [])
        let allowed = try await Self.check("http://internal.corp/", [Self.v4("10.0.0.1")], allowlist: ["internal.corp"])
        #expect(allowed == .init(resolvedIp: "10.0.0.1", originalHost: "internal.corp"))
        await Self.expectBlocked("http://cgnat.test/", [Self.v4("100.64.0.1")])
        #expect(try await Self.check("http://public.test/", [Self.v4("8.8.8.8"), Self.v4("1.1.1.1")]).resolvedIp == "8.8.8.8")
    }

    @Test func ssrfMatchesNodeVectors() async throws {
        for c in Vectors["ssrf"].array {
            let url = c["url"]!.string!
            let records = (c["records"]?.arrayValue ?? []).map { ResolvedAddress(address: $0["address"]!.string!, family: $0["family"]!.intValue!) }
            let allowlist = c["allowlist"]?.arrayValue?.map { $0.string! }
            let result = c["result"]!
            do {
                let v = try await Self.check(url, records, allowlist: allowlist)
                #expect(result["ok"]?["resolvedIp"]?.string == v.resolvedIp, "\(url)")
                #expect(result["ok"]?["originalHost"]?.string == v.originalHost, "\(url)")
            } catch let e as SSRFBlockedError {
                #expect(result["error"]?.string == e.message, "\(url)")
            }
        }
        for p in Vectors["hostnames"].array {
            #expect(WHATWGURL.parse(p[0]!.string!)?.hostname == p[1]!.string!)
        }
    }

    @Test func ipHelpers() {
        #expect(IP.isIP("1.2.3.4") == 4)
        #expect(IP.isIP("01.2.3.4") == 0)
        #expect(IP.isIP("256.1.1.1") == 0)
        #expect(IP.isIP("::") == 6)
        #expect(IP.isIP("fe80::1%eth0") == 6)
        #expect(IP.isIP("1::2::3") == 0)
        #expect(IP.isIP("example.com") == 0)
        #expect(IP.serializeIPv6([0, 0, 0, 0, 0, 0, 0, 0]) == "::")
        #expect(IP.serializeIPv6([1, 0, 0, 0, 0, 0, 0, 0]) == "1::")
        #expect(IP.serializeIPv6([1, 2, 3, 4, 5, 6, 7, 8]) == "1:2:3:4:5:6:7:8")
    }

    // MARK: uploader.test.ts

    static func uploader(
        _ config: OutboundConfig = OutboundConfig(), fetch: @escaping @Sendable (LarkHTTPRequest) -> LarkHTTPResponse = { _ in
            LarkHTTPResponse(statusCode: 200, headers: [:], body: Data([1, 2, 3]))
        }
    ) throws -> (MediaUploader, MockHTTPClient) {
        let http = TestSupport.http { req in
            switch req.url.path {
            case "/open-apis/im/v1/images": return MockHTTPClient.json(["code": 0, "data": ["image_key": "img_default"]])
            case "/open-apis/im/v1/files": return MockHTTPClient.json(["code": 0, "data": ["file_key": "file_default"]])
            default: return fetch(req)
            }
        }
        let client = try LarkClient(LarkConfiguration(appId: "cli_test", appSecret: "s", logLevel: .fatal, cache: DefaultLarkCache(), httpClient: http))
        return (MediaUploader(api: ChannelAPI(client: client), config: config), http)
    }

    static func uploads(_ http: MockHTTPClient) -> [LarkHTTPRequest] { http.apiRequests.filter { $0.url.host == "open.feishu.cn" } }
    static func fetches(_ http: MockHTTPClient) -> [LarkHTTPRequest] { http.apiRequests.filter { $0.url.host != "open.feishu.cn" } }

    static func expectUploadFailed(_ input: MediaUploader.Input, _ config: OutboundConfig = OutboundConfig(), contains: String? = nil) async throws {
        let (u, _) = try uploader(config)
        do {
            _ = try await u.upload(input)
            Issue.record("expected upload_failed")
        } catch let e as LarkChannelError {
            #expect(e.code == .uploadFailed)
            if let contains { #expect(e.message.contains(contains), "\(e.message)") }
        }
    }

    @Test func dataSourcePassesThrough() async throws {
        let (u, http) = try Self.uploader()
        let r = try await u.upload(.init(kind: .image, source: .data(Data("hello bytes".utf8))))
        #expect(r == .init(kind: .image, fileKey: "img_default"))
        let form = TestSupport.multipart(try #require(Self.uploads(http).first))
        #expect(form["image_type"] == Data("message".utf8))
        #expect(form["image"] == Data("hello bytes".utf8))
        #expect(Self.fetches(http).isEmpty)
    }

    static func tempDir(_ prefix: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func localFileIsRead() async throws {
        let dir = try Self.tempDir("uploader-test-")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.bin")
        try Data("on-disk content".utf8).write(to: file)
        let (u, http) = try Self.uploader()
        _ = try await u.upload(.init(kind: .image, source: .location(file.path)))
        #expect(TestSupport.multipart(try #require(Self.uploads(http).first))["image"] == Data("on-disk content".utf8))
        #expect(Self.fetches(http).isEmpty)
    }

    @Test func missingLocalPathFails() async throws {
        try await Self.expectUploadFailed(
            .init(kind: .image, source: "/definitely/does/not/exist/here.png"), contains: "neither an http(s) URL nor a readable local file")
    }

    @Test(arguments: ["/etc/passwd", "/proc/self/environ", "/sys/kernel/version", "/dev/null", "/tmp/../etc/passwd", "/etc"])
    func posixBlocklist(_ path: String) async throws {
        try await Self.expectUploadFailed(.init(kind: .image, source: .location(path)), contains: "file path is not allowed")
    }

    @Test func allowedFileDirs() async throws {
        let allowed = try Self.tempDir("lfi-ok-")
        let outside = try Self.tempDir("lfi-out-")
        defer {
            try? FileManager.default.removeItem(at: allowed)
            try? FileManager.default.removeItem(at: outside)
        }
        let inside = allowed.appendingPathComponent("ok.bin")
        try Data("allowed".utf8).write(to: inside)
        let (u, http) = try Self.uploader(.init(allowedFileDirs: [allowed.path]))
        _ = try await u.upload(.init(kind: .image, source: .location(inside.path)))
        #expect(Self.uploads(http).count == 1)

        let nope = outside.appendingPathComponent("nope.bin")
        try Data("x".utf8).write(to: nope)
        try await Self.expectUploadFailed(
            .init(kind: .image, source: .location(nope.path)), .init(allowedFileDirs: [allowed.path]), contains: "outside allowed directories")

        // A symlink inside the allowed dir pointing out is rejected after realpath.
        let secret = outside.appendingPathComponent("real.bin")
        try Data("secret".utf8).write(to: secret)
        let link = allowed.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        try await Self.expectUploadFailed(
            .init(kind: .image, source: .location(link.path)), .init(allowedFileDirs: [allowed.path]), contains: "outside allowed directories")
    }

    @Test func relativePathsResolveAgainstCwd() {
        #expect(MediaUploader.resolvePath("/a/./b/../c") == "/a/c")
        #expect(MediaUploader.resolvePath("/../..") == "/")
        #expect(MediaUploader.resolvePath("x/y").hasPrefix(FileManager.default.currentDirectoryPath))
    }

    @Test func urlFetchWithGuard() async throws {
        let resolver = StubResolver(records: [Self.v4("8.8.8.8")])
        let (u, http) = try Self.uploader(.init(hostResolver: resolver))
        _ = try await u.upload(.init(kind: .image, source: "https://evil.example.com/a.png"))
        let fetch = try #require(Self.fetches(http).first)
        // URL is not rewritten (TLS SNI / certificate checks use the hostname).
        #expect(fetch.url.absoluteString == "https://evil.example.com/a.png")
        #expect(fetch.method == .get)
        #expect(fetch.timeout == 15)
        #expect(fetch.headers["Authorization"] == nil)
        #expect(resolver.calls.items == ["evil.example.com"])
        #expect(TestSupport.multipart(try #require(Self.uploads(http).first))["image"] == Data([1, 2, 3]))
    }

    @Test func urlFetchWithGuardDisabledSkipsDns() async throws {
        let resolver = StubResolver(records: [Self.v4("10.0.0.1")])
        let (u, http) = try Self.uploader(.init(ssrfGuard: .disabled, hostResolver: resolver))
        _ = try await u.upload(.init(kind: .image, source: "HTTPS://example.com/a.png"))
        #expect(Self.fetches(http).count == 1)
        #expect(resolver.calls.count == 0)
    }

    @Test func urlBlockedBySSRFGuard() async throws {
        let (u, http) = try Self.uploader(.init(hostResolver: StubResolver(records: [Self.v4("169.254.169.254")])))
        do {
            _ = try await u.upload(.init(kind: .image, source: "http://metadata.test/x"))
            Issue.record("expected ssrf_blocked")
        } catch let e as LarkChannelError {
            #expect(e.code == .ssrfBlocked)
            #expect(e.message == "URL blocked: Error: ssrf_blocked: 169.254.169.254")
        }
        #expect(Self.fetches(http).isEmpty)
        let (u2, _) = try Self.uploader(.init(ssrfGuard: .allowlist(["metadata.test"]), hostResolver: StubResolver(records: [Self.v4("169.254.169.254")])))
        _ = try await u2.upload(.init(kind: .image, source: "http://metadata.test/x"))
    }

    @Test func urlFetchFailuresAreUploadFailed() async throws {
        let (u, _) = try Self.uploader(.init(ssrfGuard: .disabled)) { _ in LarkHTTPResponse(statusCode: 404, headers: [:], body: Data()) }
        do {
            _ = try await u.upload(.init(kind: .image, source: "https://example.com/missing.png"))
            Issue.record("expected upload_failed")
        } catch let e as LarkChannelError {
            #expect(e.code == .uploadFailed)
            #expect(e.message == "fetch source URL failed")
        }
        let (big, _) = try Self.uploader(.init(ssrfGuard: .disabled)) { _ in
            LarkHTTPResponse(statusCode: 200, headers: [:], body: Data(count: MediaUploader.urlMaxBytes + 1))
        }
        await #expect(throws: LarkChannelError.self) { _ = try await big.upload(.init(kind: .image, source: "https://example.com/big")) }
    }

    @Test func imageResponseShapes() async throws {
        func run(_ body: JSONValue) async throws -> MediaUploader.Result {
            let http = TestSupport.http { _ in MockHTTPClient.json(body) }
            let client = try LarkClient(LarkConfiguration(appId: "cli_test", appSecret: "s", logLevel: .fatal, cache: DefaultLarkCache(), httpClient: http))
            return try await MediaUploader(api: ChannelAPI(client: client), config: .init()).upload(.init(kind: .image, source: .data(Data("x".utf8))))
        }
        #expect(try await run(["code": 0, "data": ["image_key": "img_nested"]]) == .init(kind: .image, fileKey: "img_nested"))
        #expect(try await run(["code": 0, "image_key": "img_top"]).fileKey == "img_top")
        do {
            _ = try await run(["code": 0])
            Issue.record("expected upload_failed")
        } catch let e as LarkChannelError {
            #expect(e.code == .uploadFailed)
            #expect(e.message == "image upload failed")
        }
    }

    @Test func fileResponseShapesAndKinds() async throws {
        let (u, http) = try Self.uploader()
        let plain = try await u.upload(.init(kind: .file, source: .data(Data("plain text, no duration".utf8)), fileName: "doc.txt"))
        #expect(plain == .init(kind: .file, fileKey: "file_default", durationMs: nil))
        let form = TestSupport.multipart(try #require(Self.uploads(http).last))
        #expect(form["file_type"] == Data("stream".utf8))
        #expect(form["file_name"] == Data("doc.txt".utf8))
        #expect(form["duration"] == nil)

        let audio = try await u.upload(.init(kind: .audio, source: .data(Data("any bytes".utf8)), duration: 3000))
        #expect(audio == .init(kind: .audio, fileKey: "file_default", durationMs: 3000))
        let aform = TestSupport.multipart(try #require(Self.uploads(http).last))
        #expect(aform["file_type"] == Data("opus".utf8))
        #expect(aform["file_name"] == Data("voice.opus".utf8))
        #expect(aform["duration"] == Data("3000".utf8))

        let video = try await u.upload(.init(kind: .video, source: .data(Data("any".utf8)), duration: 5000))
        #expect(video.kind == .video)
        let vform = TestSupport.multipart(try #require(Self.uploads(http).last))
        #expect(vform["file_type"] == Data("mp4".utf8) && vform["duration"] == Data("5000".utf8))

        // Parsed durations when none is given.
        let parsed = try await u.upload(.init(kind: .audio, source: .data(Self.oggPage(96_000))))
        #expect(parsed.durationMs == 2000)
        #expect(try await u.upload(.init(kind: .video, source: .data(Self.mp4(timescale: 1000, duration: 1234)))).durationMs == 1234)

        #expect(try await u.upload(.init(kind: .image, source: .data(Data("any bytes".utf8)))).kind == .image)

        let http2 = TestSupport.http { _ in MockHTTPClient.json(["code": 0, "file_key": "file_top"]) }
        let client = try LarkClient(LarkConfiguration(appId: "cli_test", appSecret: "s", logLevel: .fatal, cache: DefaultLarkCache(), httpClient: http2))
        #expect(try await MediaUploader(api: ChannelAPI(client: client), config: .init()).upload(.init(kind: .file, source: .data(Data()), fileName: "a")).fileKey == "file_top")
    }

    @Test func undeterminableDurationsFail() async throws {
        try await Self.expectUploadFailed(.init(kind: .audio, source: .data(Data("not a valid opus stream".utf8))), contains: "duration could not be determined for audio")
        try await Self.expectUploadFailed(.init(kind: .video, source: .data(Data("not an mp4".utf8))), contains: "duration could not be determined for video")
    }
}
