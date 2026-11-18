/// Splitting one row into fields. Scalar on purpose: it only runs on the
/// rows about to be drawn, a few KB at a time.
enum Fields {
    static let quote = UInt8(ascii: "\"")

    /// Fields of `row`, outer quotes removed and "" turned into ".
    /// An empty row is one empty field; "a," is two fields.
    static func split(_ row: UnsafeRawBufferPointer, delimiter: UInt8) -> [String] {
        var out: [String] = []
        var start = 0, quotes = 0, inside = false
        for i in 0...row.count {
            if i < row.count {
                let c = row[i]
                if c == quote { inside.toggle(); quotes += 1; continue }
                if c != delimiter || inside { continue }
            }
            out.append(field(UnsafeRawBufferPointer(rebasing: row[start..<i]), quotes: quotes))
            start = i + 1
            quotes = 0
        }
        return out
    }

    private static func field(_ raw: UnsafeRawBufferPointer, quotes: Int) -> String {
        let quoted = raw.count >= 2 && raw[0] == quote && raw[raw.count - 1] == quote
        guard quoted else { return String(decoding: raw, as: UTF8.self) }
        let content = UnsafeRawBufferPointer(rebasing: raw[1..<(raw.count - 1)])
        guard quotes > 2 else { return String(decoding: content, as: UTF8.self) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(content.count)
        var i = 0
        while i < content.count {
            bytes.append(content[i])
            if content[i] == quote, i + 1 < content.count, content[i + 1] == quote { i += 1 }
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
