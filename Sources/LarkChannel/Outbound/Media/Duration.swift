import Foundation

/// Ports of node-sdk `media/duration-ogg.ts` and `media/duration-mp4.ts`.
enum MediaDuration {
    /// Opus/Ogg duration in ms: the granule position (48 kHz samples) of the
    /// last `OggS` page, found by scanning backwards.
    static func parseOpusDuration(_ data: Data) -> Int? {
        let buf = [UInt8](data)
        guard buf.count >= 27 else { return nil }
        var i = buf.count - 27
        while i >= 0 {
            if buf[i] == 0x4F && buf[i + 1] == 0x67 && buf[i + 2] == 0x67 && buf[i + 3] == 0x53 {
                var granule: UInt64 = 0
                for k in 0..<8 { granule |= UInt64(buf[i + 6 + k]) << (8 * UInt64(k)) }
                let signed = Int64(bitPattern: granule)
                if signed < 0 { return nil }
                let ms = Double(signed) / 48
                guard ms.isFinite, ms >= 0 else { return nil }
                return Int((ms + 0.5).rounded(.down))
            }
            i -= 1
        }
        return nil
    }

    /// MP4 duration in ms from `moov → mvhd` (versions 0 and 1).
    static func parseMp4Duration(_ data: Data) -> Int? {
        let buf = [UInt8](data)
        guard buf.count >= 16 else { return nil }
        guard let moov = findBoxPayload(buf, 0, buf.count, "moov") else { return nil }
        guard let mvhd = findBoxPayload(buf, moov.start, moov.end, "mvhd") else { return nil }

        let p = mvhd.start
        if p + 4 > buf.count { return nil }
        let version = buf[p]
        let base = p + 4

        let timescale: UInt32
        let duration: Double
        if version == 1 {
            if base + 28 > buf.count { return nil }
            timescale = readU32(buf, base + 16)
            duration = Double(readU64(buf, base + 20))
        } else {
            if base + 16 > buf.count { return nil }
            timescale = readU32(buf, base + 8)
            duration = Double(readU32(buf, base + 12))
        }
        if timescale == 0 { return nil }
        let ms = (duration / Double(timescale)) * 1000
        guard ms.isFinite else { return nil }
        return Int((ms + 0.5).rounded(.down))
    }

    private static func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    private static func readU64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = v << 8 | UInt64(b[o + k]) }
        return v
    }

    /// Walks the boxes in `[begin, end)` and returns the payload range of `name`.
    private static func findBoxPayload(_ buf: [UInt8], _ begin: Int, _ end: Int, _ name: String) -> (start: Int, end: Int)? {
        var p = begin
        while p + 8 <= end && p + 8 <= buf.count {
            let size = readU32(buf, p)
            let type = String(decoding: buf[(p + 4)..<(p + 8)].map { $0 & 0x7F }, as: UTF8.self)
            let boxEnd: Int
            if size == 1 {
                // node reads the 64-bit size without a bounds check (throws RangeError).
                guard p + 16 <= buf.count else { return nil }
                let large = readU64(buf, p + 8)
                guard large <= UInt64(Int.max - p) else { return nil }
                boxEnd = p + Int(large)
            } else if size == 0 {
                boxEnd = end  // box extends to end-of-file
            } else {
                boxEnd = p + Int(size)
            }
            if boxEnd <= p || boxEnd > end { return nil }
            if type == name {
                return (size == 1 ? p + 16 : p + 8, boxEnd)
            }
            p = boxEnd
        }
        return nil
    }
}
