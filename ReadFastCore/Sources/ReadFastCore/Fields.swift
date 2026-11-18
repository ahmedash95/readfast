/// Splitting one row into fields. Scalar on purpose: it only runs on the
/// rows about to be drawn, a few KB at a time.
enum Fields {
    static let quote = UInt8(ascii: "\"")

    /// Fields of `row`, outer quotes removed and "" turned into ".
    /// An empty row is one empty field; "a," is two fields.
    static func split(_ row: UnsafeRawBufferPointer, delimiter: UInt8, encoding: CSVEncoding = .utf8) -> [String] {
        switch encoding {
        case .utf8: split(row, delimiter) { String(decoding: UnsafeRawBufferPointer(rebasing: $0), as: UTF8.self) }
        case .windows1252: split(row, delimiter) { Windows1252.decode(UnsafeRawBufferPointer(rebasing: $0)) }
        case .utf16LE, .utf16BE: split(encoding.units(row), delimiter) { String(decoding: $0, as: UTF16.self) }
        }
    }

    /// The split over code units (bytes or UTF-16 units, 0-based); `decode` turns a slice into a String.
    private static func split<C: RandomAccessCollection>(
        _ row: C, _ delimiter: UInt8, decode: (C.SubSequence) -> String
    ) -> [String] where C.Index == Int, C.Element: FixedWidthInteger {
        let quote = C.Element(quote), delimiter = C.Element(delimiter)
        var out: [String] = []
        var start = 0, quotes = 0, inside = false
        for i in 0...row.count {
            if i < row.count {
                let c = row[i]
                if c == quote { inside.toggle(); quotes += 1; continue }
                if c != delimiter || inside { continue }
            }
            out.append(field(row, start..<i, quotes: quotes, decode: decode))
            start = i + 1
            quotes = 0
        }
        return out
    }

    private static func field<C: RandomAccessCollection>(
        _ row: C, _ r: Range<Int>, quotes: Int, decode: (C.SubSequence) -> String
    ) -> String where C.Index == Int, C.Element: FixedWidthInteger {
        let quote = C.Element(quote)
        guard r.count >= 2, row[r.lowerBound] == quote, row[r.upperBound - 1] == quote else { return decode(row[r]) }
        let content = (r.lowerBound + 1)..<(r.upperBound - 1)
        guard quotes > 2 else { return decode(row[content]) }
        // "" → ": decode the runs between doubled quotes, each keeping one of the two
        var s = "", piece = content.lowerBound, i = content.lowerBound
        while i < content.upperBound {
            if row[i] == quote, i + 1 < content.upperBound, row[i + 1] == quote {
                s += decode(row[piece...i])
                i += 2
                piece = i
            } else {
                i += 1
            }
        }
        return s + decode(row[piece..<content.upperBound])
    }

    /// The candidate that splits `row` into the most fields. Ties and no match: ','.
    static func sniffDelimiter(_ row: UnsafeRawBufferPointer, encoding: CSVEncoding = .utf8) -> UInt8 {
        encoding.unitWidth == 2 ? sniff(encoding.units(row)) : sniff(row)
    }

    private static func sniff<C: Collection>(_ row: C) -> UInt8 where C.Element: FixedWidthInteger {
        let candidates: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "\t"), UInt8(ascii: "|")]
        var counts = [Int](repeating: 0, count: candidates.count)
        var inside = false
        for c in row {
            if c == quote { inside.toggle() }
            if inside || c >= 0x80 { continue }
            if let k = candidates.firstIndex(of: UInt8(c)) { counts[k] += 1 }
        }
        return candidates[counts.indices.max { counts[$0] < counts[$1] || (counts[$0] == counts[$1] && $0 > $1) }!]
    }
}
