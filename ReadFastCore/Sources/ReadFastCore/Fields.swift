/// Splitting one row into fields. Scalar on purpose: it only runs on the
/// rows about to be drawn, a few KB at a time.
enum Fields {
    static let quote = UInt8(ascii: "\"")

    /// Fields of `row`, outer quotes removed and "" turned into ".
    /// An empty row is one empty field; "a," is two fields.
    /// Same quote rule as the scan (readfast.h): a quote opens a quoted field
    /// only as a field's first unit; anywhere else it's a plain unit.
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
        var start = 0, quoted = false, inside = false, closed = false
        for i in 0...row.count {
            if i < row.count {
                let c = row[i]
                let afterClose = closed
                closed = false
                if c == quote, i == start || inside || afterClose {
                    // opens, closes, or (right after a close) is the 2nd half of ""
                    quoted = true
                    closed = inside
                    inside.toggle()
                    continue
                }
                if c != delimiter || inside { continue }
            }
            out.append(quoted && !inside ? unquote(row, start..<i, decode: decode) : decode(row[start..<i]))
            start = i + 1
            quoted = false
        }
        return out
    }

    /// `"a ""b"" c"rest` → `a "b" crest`. Only called on closed quoted fields:
    /// decodes the runs between quotes, "" adding one quote.
    private static func unquote<C: RandomAccessCollection>(
        _ row: C, _ r: Range<Int>, decode: (C.SubSequence) -> String
    ) -> String where C.Index == Int, C.Element: FixedWidthInteger {
        let quote = C.Element(quote)
        var s = "", piece = r.lowerBound + 1, i = piece
        while i < r.upperBound {
            guard row[i] == quote else { i += 1; continue }
            s += decode(row[piece..<i])
            if i + 1 < r.upperBound, row[i + 1] == quote {
                s += "\""
                i += 2
                piece = i
            } else {
                return s + decode(row[(i + 1)..<r.upperBound]) // the closing quote; the rest is plain
            }
        }
        return s + decode(row[piece..<r.upperBound])
    }
}
