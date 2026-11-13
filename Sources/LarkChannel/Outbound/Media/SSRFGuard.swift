import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One DNS answer (node `dns.lookup(host, { all: true })` record).
public struct ResolvedAddress: Sendable, Hashable {
    public var address: String
    /// 4 or 6.
    public var family: Int
    public init(address: String, family: Int) {
        self.address = address
        self.family = family
    }
}

/// DNS resolver used by the SSRF guard.
public protocol HostResolver: Sendable {
    /// Returns every address of `host` (like `dns.lookup(host, { all: true })`).
    func lookup(_ host: String) async throws -> [ResolvedAddress]
}

/// `getaddrinfo`-backed resolver (the default).
public struct SystemHostResolver: HostResolver {
    public init() {}

    public func lookup(_ host: String) async throws -> [ResolvedAddress] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(with: Result { try Self.resolve(host) })
            }
        }
    }

    struct LookupError: Error, CustomStringConvertible {
        var host: String
        var code: Int32
        var description: String { "Error: getaddrinfo ENOTFOUND \(host) (\(code))" }
    }

    static func resolve(_ host: String) throws -> [ResolvedAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc) || canImport(Musl)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &res)
        guard rc == 0, let first = res else { throw LookupError(host: host, code: rc) }
        defer { freeaddrinfo(first) }
        var out: [ResolvedAddress] = []
        var seen = Set<String>()
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            var buf = [CChar](repeating: 0, count: 1025)  // NI_MAXHOST
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let addr = String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let family = ai.pointee.ai_family == AF_INET6 ? 6 : 4
                if seen.insert(addr).inserted { out.append(ResolvedAddress(address: addr, family: family)) }
            }
            cur = ai.pointee.ai_next
        }
        return out
    }
}

/// Error raised by the SSRF guard; its message starts with `ssrf_blocked`.
struct SSRFBlockedError: Error, CustomStringConvertible {
    var message: String
    var description: String { "Error: \(message)" }
}

/// Port of node-sdk `media/ssrf-guard.ts`.
///
/// Deviation: node-sdk pins the subsequent fetch to the validated IP with a
/// custom `lookup` (DNS-rebinding defense). `URLSession` / ``LarkHTTPClient``
/// cannot pin a connection to an IP while keeping TLS SNI, so the Swift port
/// validates and returns the pinned IP but the fetch re-resolves the host.
enum SSRFGuard {
    struct Validation: Sendable, Equatable {
        var resolvedIp: String
        var originalHost: String
    }

    /// Validates that `url` is http(s) and does not resolve to an internal /
    /// reserved address (every DNS record is checked). Allowlisted hostnames
    /// skip the public-IP check.
    static func assertPublicURL(_ url: String, allowlist: [String]? = nil, resolver: any HostResolver) async throws -> Validation {
        guard let parsed = WHATWGURL.parse(url) else { throw SSRFBlockedError(message: "Invalid URL") }
        if parsed.scheme != "http" && parsed.scheme != "https" {
            throw SSRFBlockedError(message: "ssrf_blocked: protocol \(parsed.scheme):")
        }
        let rawHost = parsed.hostname
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        let allowlisted = allowlist?.contains(host) ?? false

        if IP.isIP(host) != 0 {
            if !allowlisted { try assertIpPublic(host) }
            return Validation(resolvedIp: host, originalHost: host)
        }
        let records = try await resolver.lookup(host)
        if records.isEmpty { throw SSRFBlockedError(message: "ssrf_blocked: no DNS records for \(host)") }
        if !allowlisted {
            // Reject if ANY record is private (no DNS round-robin lottery).
            for r in records { try assertIpPublic(r.address) }
        }
        return Validation(resolvedIp: records[0].address, originalHost: host)
    }

    static func assertIpPublic(_ ip: String) throws {
        let v = IP.isIP(ip)
        if v == 4 && IP.ipv4Blocked(ip) { throw SSRFBlockedError(message: "ssrf_blocked: \(ip)") }
        if v == 6 && IP.ipv6Blocked(ip) { throw SSRFBlockedError(message: "ssrf_blocked: \(ip)") }
        if v == 0 { throw SSRFBlockedError(message: "ssrf_blocked: not a valid IP: \(ip)") }
    }
}

/// IP helpers (node `net.isIP` + the guard's CIDR tables).
enum IP {
    /// 128-bit unsigned value as (high, low).
    struct U128: Equatable {
        var hi: UInt64
        var lo: UInt64

        static func & (a: U128, b: U128) -> U128 { U128(hi: a.hi & b.hi, lo: a.lo & b.lo) }

        /// Mask with the top `bits` bits set.
        static func prefixMask(_ bits: Int) -> U128 {
            if bits <= 0 { return U128(hi: 0, lo: 0) }
            if bits >= 128 { return U128(hi: .max, lo: .max) }
            if bits <= 64 { return U128(hi: bits == 64 ? .max : ~(UInt64.max >> UInt64(bits)), lo: 0) }
            return U128(hi: .max, lo: ~(UInt64.max >> UInt64(bits - 64)))
        }
    }

    static let blockedV4: [(UInt32, Int)] = [
        (0x0000_0000, 8),  // 0.0.0.0/8
        (0x0A00_0000, 8),  // 10.0.0.0/8
        (0x7F00_0000, 8),  // 127.0.0.0/8
        (0xA9FE_0000, 16),  // 169.254.0.0/16
        (0xAC10_0000, 12),  // 172.16.0.0/12
        (0xC0A8_0000, 16),  // 192.168.0.0/16
        (0x6440_0000, 10),  // 100.64.0.0/10 (CGNAT)
        (0xC000_0000, 24),  // 192.0.0.0/24
        (0xC000_0200, 24),  // 192.0.2.0/24
        (0xC612_0000, 15),  // 198.18.0.0/15
        (0xC633_6400, 24),  // 198.51.100.0/24
        (0xCB00_7100, 24),  // 203.0.113.0/24
        (0xE000_0000, 4),  // 224.0.0.0/4 (multicast)
        (0xF000_0000, 4),  // 240.0.0.0/4 (reserved)
    ]

    static let blockedV6: [(U128, Int)] = [
        (U128(hi: 0xFE80_0000_0000_0000, lo: 0), 10),  // fe80::/10 link-local
        (U128(hi: 0xFC00_0000_0000_0000, lo: 0), 7),  // fc00::/7 ULA
        (U128(hi: 0xFF00_0000_0000_0000, lo: 0), 8),  // ff00::/8 multicast
        (U128(hi: 0x0100_0000_0000_0000, lo: 0), 64),  // 100::/64 discard-only
        (U128(hi: 0x2001_0DB8_0000_0000, lo: 0), 32),  // 2001:db8::/32 documentation
        (U128(hi: 0x2001_0000_0000_0000, lo: 0), 32),  // 2001::/32 Teredo
    ]

    /// `net.isIP`: 4, 6 or 0.
    static func isIP(_ s: String) -> Int {
        if isIPv4(s) { return 4 }
        if isIPv6(s) { return 6 }
        return 0
    }

    /// Strict dotted-quad without leading zeros (node `isIPv4`).
    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            if p.count > 1 && p.hasPrefix("0") { return false }
            guard let v = Int(p), v <= 255 else { return false }
        }
        return true
    }

    /// node `isIPv6` (accepts an optional `%zone` suffix).
    static func isIPv6(_ s: String) -> Bool {
        var addr = s
        if let pct = s.firstIndex(of: "%") {
            let zone = s[s.index(after: pct)...]
            guard !zone.isEmpty, zone.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) }) else {
                return false
            }
            addr = String(s[..<pct])
        }
        guard !addr.contains("%") else { return false }
        return (try? parseIPv6(addr)) != nil && strictIPv6Syntax(addr)
    }

    /// Rejects forms `parseIPv6` tolerates but `isIPv6` does not (empty groups
    /// outside `::`, more than four hex digits, leading/trailing single `:`).
    private static func strictIPv6Syntax(_ addr: String) -> Bool {
        let lower = addr.lowercased()
        let halves = lower.components(separatedBy: "::")
        if halves.count > 2 { return false }
        for (idx, half) in halves.enumerated() where !half.isEmpty {
            let groups = half.components(separatedBy: ":")
            for (gi, g) in groups.enumerated() {
                let isLast = idx == halves.count - 1 && gi == groups.count - 1
                if g.contains(".") {
                    if !(isLast && isIPv4(g)) { return false }
                    continue
                }
                if g.isEmpty || g.count > 4 || !g.allSatisfy({ $0.isHexDigit }) { return false }
            }
        }
        if halves.count == 1 && lower.components(separatedBy: ":").count != (lower.contains(".") ? 7 : 8) { return false }
        return true
    }

    static func ipv4Number(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4 else { return nil }
        var n: UInt32 = 0
        for p in parts {
            guard let p, p >= 0, p <= 255 else { return nil }
            n = n << 8 | UInt32(p)
        }
        return n
    }

    static func ipv4Blocked(_ ip: String) -> Bool {
        guard let n = ipv4Number(ip) else { return true }
        return blockedV4.contains { net, bits in
            let mask: UInt32 = bits == 0 ? 0 : UInt32.max << UInt32(32 - bits)
            return n & mask == net & mask
        }
    }

    static func ipv4String(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }

    static func ipv6Blocked(_ ip: String) -> Bool {
        guard let n = try? parseIPv6(ip) else { return true }  // fail closed
        let high96 = n & U128(hi: .max, lo: 0xFFFF_FFFF_0000_0000)
        let mapped = U128(hi: 0, lo: 0x0000_FFFF_0000_0000)  // ::ffff:0:0/96
        let compat = U128(hi: 0, lo: 0)  // ::/96
        let nat64 = U128(hi: 0x0064_FF9B_0000_0000, lo: 0)  // 64:ff9b::/96
        if high96 == mapped || high96 == nat64 || high96 == compat {
            return ipv4Blocked(ipv4String(UInt32(n.lo & 0xFFFF_FFFF)))
        }
        return blockedV6.contains { net, bits in
            let mask = U128.prefixMask(bits)
            return n & mask == net & mask
        }
    }

    struct ParseError: Error {}

    /// Parses any IPv6 text form (compressed, expanded, IPv4-suffixed, `%zone`).
    static func parseIPv6(_ ip: String) throws -> U128 {
        let groups = try ipv6Groups(ip)
        var hi: UInt64 = 0, lo: UInt64 = 0
        for (i, g) in groups.enumerated() {
            if i < 4 { hi = hi << 16 | UInt64(g) } else { lo = lo << 16 | UInt64(g) }
        }
        return U128(hi: hi, lo: lo)
    }

    /// The eight 16-bit groups of an IPv6 address.
    static func ipv6Groups(_ ip: String) throws -> [UInt16] {
        var addr = String(ip.split(separator: "%", omittingEmptySubsequences: false).first ?? "").lowercased()

        // IPv4 dotted suffix → two hex groups.
        if let lastColon = addr.lastIndex(of: ":") {
            let tail = String(addr[addr.index(after: lastColon)...])
            let pieces = tail.split(separator: ".", omittingEmptySubsequences: false)
            if pieces.count == 4, pieces.allSatisfy({ (1...3).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isNumber } }) {
                let nums = pieces.compactMap { Int($0) }
                guard nums.count == 4, nums.allSatisfy({ $0 <= 255 }) else { throw ParseError() }
                let h1 = String((nums[0] << 8) | nums[1], radix: 16)
                let h2 = String((nums[2] << 8) | nums[3], radix: 16)
                addr = String(addr[...lastColon]) + "\(h1):\(h2)"
            }
        }

        let halves = addr.components(separatedBy: "::")
        if halves.count > 2 { throw ParseError() }
        var groups: [String]
        if halves.count == 2 {
            let left = halves[0].isEmpty ? [] : halves[0].components(separatedBy: ":")
            let right = halves[1].isEmpty ? [] : halves[1].components(separatedBy: ":")
            let fill = 8 - left.count - right.count
            if fill < 0 { throw ParseError() }
            groups = left + Array(repeating: "0", count: fill) + right
        } else {
            groups = addr.components(separatedBy: ":")
        }
        if groups.count != 8 { throw ParseError() }
        return try groups.map { g in
            guard g.count <= 4, g.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw ParseError() }
            return UInt16(g.isEmpty ? "0" : g, radix: 16) ?? 0
        }
    }

    /// WHATWG IPv6 serialisation (lower-case hex, first longest zero run compressed).
    static func serializeIPv6(_ groups: [UInt16]) -> String {
        var bestStart = -1, bestLen = 0
        var i = 0
        while i < 8 {
            if groups[i] == 0 {
                var j = i
                while j < 8 && groups[j] == 0 { j += 1 }
                if j - i > bestLen && j - i >= 2 {
                    bestStart = i
                    bestLen = j - i
                }
                i = j
            } else {
                i += 1
            }
        }
        var out = ""
        var ignore0 = false
        for k in 0..<8 {
            if ignore0 && groups[k] == 0 { continue }
            ignore0 = false
            if k == bestStart {
                out += k == 0 ? "::" : ":"
                ignore0 = true
                continue
            }
            out += String(groups[k], radix: 16)
            if k != 7 { out += ":" }
        }
        return out
    }
}

/// Minimal WHATWG URL parsing for the SSRF guard: scheme, and a hostname
/// normalised like Node's `new URL(...).hostname` (lower-cased, IPv4
/// shorthand numbers expanded, IPv6 compressed in brackets).
enum WHATWGURL {
    struct Parsed {
        var scheme: String
        var hostname: String
    }

    static func parse(_ input: String) -> Parsed? {
        let trimmed = input.trimmingCharacters(in: CharacterSet(charactersIn: Unicode.Scalar(UInt8(0))...Unicode.Scalar(UInt8(0x20))))
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let scheme = trimmed[..<colon].lowercased()
        guard let first = scheme.first, first.isLetter,
            scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        let special = ["http", "https", "ws", "wss", "ftp", "file"].contains(scheme)
        var rest = Substring(trimmed[trimmed.index(after: colon)...]).replacingOccurrences(of: "\\", with: special ? "/" : "\\")[...]
        guard rest.hasPrefix("//") || (special && scheme != "file") else {
            return Parsed(scheme: scheme, hostname: "")
        }
        while rest.hasPrefix("/") { rest = rest.dropFirst() }
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        var host: Substring
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[...close]
        } else if let c = authority.firstIndex(of: ":") {
            host = authority[..<c]
        } else {
            host = authority
        }
        if host.isEmpty {
            if scheme == "file" { return Parsed(scheme: scheme, hostname: "") }
            return nil
        }
        if host.hasPrefix("[") {
            guard let groups = try? IP.ipv6Groups(String(host.dropFirst().dropLast())) else { return nil }
            return Parsed(scheme: scheme, hostname: "[\(IP.serializeIPv6(groups))]")
        }
        let decoded = (String(host).removingPercentEncoding ?? String(host)).lowercased()
        if special, let v4 = parseIPv4Host(decoded) { return Parsed(scheme: scheme, hostname: v4) }
        return Parsed(scheme: scheme, hostname: decoded)
    }

    /// WHATWG IPv4 parser: 1–4 dot-separated decimal / octal (`0`) / hex (`0x`) parts.
    static func parseIPv4Host(_ host: String) -> String? {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" && parts.count > 1 { parts.removeLast() }
        guard let last = parts.last, !last.isEmpty, parseNumber(last) != nil else { return nil }
        guard parts.count <= 4 else { return nil }
        var numbers: [UInt64] = []
        for p in parts {
            guard let n = parseNumber(p) else { return nil }
            numbers.append(n)
        }
        for n in numbers.dropLast() where n > 255 { return nil }
        let lastLimit = UInt64(1) << UInt64(8 * (5 - numbers.count))
        guard numbers.last! < lastLimit else { return nil }
        var ipv4 = numbers.last!
        for (i, n) in numbers.dropLast().enumerated() {
            ipv4 += n << UInt64(8 * (3 - i))
        }
        guard ipv4 <= UInt64(UInt32.max) else { return nil }
        return IP.ipv4String(UInt32(ipv4))
    }

    private static func parseNumber(_ s: String) -> UInt64? {
        if s.isEmpty { return nil }
        var input = Substring(s)
        var radix = 10
        if input.count >= 2, input.hasPrefix("0x") || input.hasPrefix("0X") {
            input = input.dropFirst(2)
            radix = 16
        } else if input.count >= 2, input.hasPrefix("0") {
            input = input.dropFirst()
            radix = 8
        }
        if input.isEmpty { return 0 }
        return UInt64(input, radix: radix)
    }
}
