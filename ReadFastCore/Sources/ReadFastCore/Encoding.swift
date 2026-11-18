import CReadFast

/// Text encoding of a CSV file. Detected at open, or forced with
/// `CSVFile.open(url, encoding:)`.
public enum CSVEncoding: String, Sendable, CaseIterable {
    case utf8, utf16LE, utf16BE
    /// Windows-1252, a superset of Latin-1 for display. The fallback for
    /// anything that isn't valid UTF-8.
    case windows1252

    /// Bytes per code unit: '"', delimiters and '\n' are one unit each.
    var unitWidth: Int { self == .utf16LE || self == .utf16BE ? 2 : 1 }

    var scanUnit: rf_unit {
        switch self {
        case .utf16LE: RF_U16LE
        case .utf16BE: RF_U16BE
        case .utf8, .windows1252: RF_U8
        }
    }

    /// Byte order mark skipped at the start of the file when present.
    var bom: [UInt8] {
        switch self {
        case .utf8: [0xEF, 0xBB, 0xBF]
        case .utf16LE: [0xFF, 0xFE]
        case .utf16BE: [0xFE, 0xFF]
        case .windows1252: []
        }
    }

    /// Whether the unit at byte offset `i` is the ASCII char `c`.
    func unit(_ data: UnsafeRawBufferPointer, at i: Int, is c: UInt8) -> Bool {
        switch self {
        case .utf16LE: data[i] == c && data[i + 1] == 0
        case .utf16BE: data[i] == 0 && data[i + 1] == c
        case .utf8, .windows1252: data[i] == c
        }
    }

    /// UTF-16 code units of `raw` (even length), in host order.
    func units(_ raw: UnsafeRawBufferPointer) -> [UInt16] {
        (0..<raw.count / 2).map { i in
            let u = raw.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)
            return self == .utf16BE ? UInt16(bigEndian: u) : UInt16(littleEndian: u)
        }
    }

    /// Guess from the first bytes of a file: BOM, then BOM-less UTF-16 (ASCII-heavy
    /// text has a zero byte in most units, always on the same side), then valid
    /// UTF-8, else Windows-1252. `head` may cut the file mid-character unless
    /// `isWholeFile`.
    static func detect(_ head: UnsafeRawBufferPointer, isWholeFile: Bool) -> CSVEncoding {
        for e in [CSVEncoding.utf8, .utf16LE, .utf16BE] where head.starts(with: e.bom) { return e }

        // ponytail: zero-byte heuristic; non-Latin BOM-less UTF-16 (e.g. all-CJK) falls through, override covers it.
        let pairs = head.count / 2
        var zeroEven = 0, zeroOdd = 0
        for i in 0..<pairs {
            if head[2 * i] == 0 { zeroEven += 1 }
            if head[2 * i + 1] == 0 { zeroOdd += 1 }
        }
        if zeroOdd * 2 > pairs, zeroEven * 8 < zeroOdd { return .utf16LE }
        if zeroEven * 2 > pairs, zeroOdd * 8 < zeroEven { return .utf16BE }

        var end = head.count
        if !isWholeFile { // drop a character cut by the end of the sample
            var k = end
            while k > max(0, end - 3), head[k - 1] & 0xC0 == 0x80 { k -= 1 }
            if k > 0, head[k - 1] >= 0xC0 { end = k - 1 }
        }
        return String(validating: head[..<end], as: UTF8.self) != nil ? .utf8 : .windows1252
    }
}

enum Windows1252 {
    /// Byte → UTF-16 unit. Only 0x80...0x9F differ from Latin-1; the five
    /// undefined bytes there map to the C1 control of the same value.
    static let table: [UInt16] = (0...255).map { b in
        let high: [UInt16] = [
            0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
            0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
        ]
        return (0x80...0x9F).contains(b) ? high[b - 0x80] : UInt16(b)
    }

    static func decode(_ raw: UnsafeRawBufferPointer) -> String {
        if !raw.contains(where: { $0 >= 0x80 }) { return String(decoding: raw, as: UTF8.self) } // ASCII
        return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: raw.count) { buf in
            for (i, b) in raw.enumerated() { buf[i] = table[Int(b)] }
            return String(decoding: buf, as: UTF16.self)
        }
    }
}
