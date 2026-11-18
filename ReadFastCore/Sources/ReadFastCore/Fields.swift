/// Splitting one row into fields. Scalar on purpose: it only runs on the
/// rows about to be drawn, a few KB at a time.
enum Fields {
    static let quote = UInt8(ascii: "\"")

    /// Fields of `row`, outer quotes removed and "" turned into ".
    /// An empty row is one empty field; "a," is two fields.
    /// Same quote rule as the scan (readfast.h): a quote opens a quoted field
    /// only as a field's first byte; anywhere else it's a plain byte.
    static func split(_ row: UnsafeRawBufferPointer, delimiter: UInt8) -> [String] {
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
            let raw = UnsafeRawBufferPointer(rebasing: row[start..<i])
            out.append(quoted && !inside ? unquote(raw) : String(decoding: raw, as: UTF8.self))
            start = i + 1
            quoted = false
        }
        return out
    }

    /// `"a ""b"" c"rest` → `a "b" crest`. Only called on closed quoted fields.
    private static func unquote(_ raw: UnsafeRawBufferPointer) -> String {
        if raw[1...].firstIndex(of: quote) == raw.count - 1 { // "plain": no escapes, nothing after
            return String(decoding: UnsafeRawBufferPointer(rebasing: raw[1..<(raw.count - 1)]), as: UTF8.self)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.count)
        var i = 1
        while i < raw.count {
            if raw[i] == quote {
                if i + 1 < raw.count, raw[i + 1] == quote { bytes.append(quote); i += 2; continue }
                bytes += raw[(i + 1)...] // the closing quote; the rest is plain
                break
            }
            bytes.append(raw[i])
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The candidate that splits `row` into the most fields. Ties and no match: ','.
    static func sniffDelimiter(_ row: UnsafeRawBufferPointer) -> UInt8 {
        let candidates: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "\t"), UInt8(ascii: "|")]
        var counts = [Int](repeating: 0, count: candidates.count)
        var inside = false
        for c in row {
            if c == quote { inside.toggle() }
            if inside { continue }
            if let k = candidates.firstIndex(of: c) { counts[k] += 1 }
        }
        return candidates[counts.indices.max { counts[$0] < counts[$1] || (counts[$0] == counts[$1] && $0 > $1) }!]
    }
}
