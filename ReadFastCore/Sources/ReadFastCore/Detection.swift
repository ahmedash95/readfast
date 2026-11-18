import CReadFast

/// Delimiter and header sniffing over a handful of preview rows. Scalar: it
/// runs once per `open`, on at most `sampleRows` rows (the delimiter from the
/// first `sampleBytes`, the header from rows cut at `sampleRowBytes`).
///
/// Not candidates: ':' (times like 12:30:00 split every row the same way) and
/// ' ' (prose splits into a consistent-looking word count). Both would win
/// over the real delimiter on ordinary files.
extension Fields {
    static let sampleRows = 50
    static let sampleRowBytes = 64 << 10
    /// How much of the file's head the delimiter sniffer reads.
    static let sampleBytes = 64 << 10
    static let delimiterCandidates: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "\t"), UInt8(ascii: "|")]

    /// The candidate whose field count is the same on the most rows (that count
    /// must be > 1), then the one with more fields, then candidate order.
    /// A title line, ragged rows and quoted delimiters don't sway it. A comma
    /// that only ever sits between digits (`1,5;2,7`) is a decimal comma: ';'
    /// wins any tie with it. Nothing fits (one column, empty): ','.
    ///
    /// `texts` are raw: it runs before the index, which needs the delimiter.
    /// Each candidate splits them into rows (at '\n', '\r\n' or '\r' outside
    /// quoted fields, up to `sampleRows`) and fields with its own quote rule
    /// (readfast.h), since where a quote opens depends on the delimiter.
    /// A text's last row without a newline counts only if it's the only row or
    /// `complete` (the text is the whole file, not a cut-off head).
    /// UTF-16 text is read as 16-bit units (a CJK unit's bytes can look like ',' or ';').
    static func sniffDelimiter(_ texts: [UnsafeRawBufferPointer], encoding: CSVEncoding = .utf8, complete: Bool = true) -> UInt8 {
        let cands = delimiterCandidates
        var counts = [[Int: Int]](repeating: [:], count: cands.count) // fields per row -> rows
        var decimalCommas = true
        var fields = [UInt32](repeating: 0, count: sampleRows)
        for (k, d) in cands.enumerated() {
            for text in texts where !text.isEmpty {
                var tail: UInt32 = 0, betweenDigits = true
                let rows = rf_sniff_rows(bytes(text), text.count, d, sampleRows, &fields, &tail, &betweenDigits, encoding.scanUnit)
                for f in fields[..<rows] { counts[k][Int(f), default: 0] += 1 }
                if tail > 0, rows == 0 || complete { counts[k][Int(tail), default: 0] += 1 } // last row, no newline
                if k == 0, !betweenDigits { decimalCommas = false }
            }
        }
        // per candidate: (rows sharing the most common count, that count); ties -> more fields
        let stats = counts.map { $0.max { ($0.value, $0.key) < ($1.value, $1.key) }.map { (rows: $0.value, fields: $0.key) } }
        var best: Int?
        for k in cands.indices {
            guard let s = stats[k], s.fields > 1 else { continue }
            if let b = best, let t = stats[b], (s.rows, s.fields) <= (t.rows, t.fields) { continue }
            best = k
        }
        if best == 0, decimalCommas, let semi = stats[1], semi.fields > 1, semi.rows >= stats[0]!.rows { return cands[1] }
        return cands[best ?? 0]
    }

    private static func isDigit<T: FixedWidthInteger>(_ c: T) -> Bool { c >= 48 && c <= 57 }

    enum Kind { case text, number, date }

    /// Rough type of a cell: dates/times (`2024-01-31`, `31/01/2024`, `12:30`),
    /// numbers (`-1.5`, `1,5`, `1e6`, `1,234.5`), anything else is text.
    static func kind(_ s: String) -> Kind {
        let t = s.utf8.drop { $0 == 32 }
        guard let first = t.first, t.contains(where: isDigit) else { return .text }
        if isDigit(first), t.allSatisfy({ isDigit($0) || "-/.:T Z+".utf8.contains($0) }), t.contains(where: { "-/:".utf8.contains($0) }) { return .date }
        if isDigit(first) || "+-.".utf8.contains(first), t.allSatisfy({ isDigit($0) || "+-.,eE ".utf8.contains($0) }) { return .number }
        return .text
    }

    /// Whether `rows[0]` is a header, by votes per column:
    /// - column below is mostly (80%) numbers or dates: +1 if the top cell is text, -1 if it's typed too;
    /// - text column: -1 if the top cell reappears below (data, not a name), +1 if every
    ///   cell below has one length and the top cell another (codes under a name);
    /// - duplicate names: -1; more than one empty name: -1.
    /// A tie is a header (all-text tables usually have one). A lone row is a header
    /// if its cells are distinct, non-empty text. No non-empty cell: no header.
    static func detectHeader(_ rows: [[String]]) -> Bool {
        guard let head = rows.first, head.contains(where: { !$0.isEmpty }) else { return false }
        let named = head.filter { !$0.isEmpty }
        let headKinds = head.map(kind)
        let data = rows.dropFirst()
        if data.isEmpty { return named.count == head.count && Set(head).count == head.count && headKinds.allSatisfy { $0 == .text } }
        var score = 0
        for (j, h) in head.enumerated() where !h.isEmpty {
            let col = data.compactMap { j < $0.count && !$0[j].isEmpty ? $0[j] : nil }
            guard !col.isEmpty else { continue }
            let kinds = col.map(kind)
            if [Kind.number, .date].contains(where: { k in kinds.filter { $0 == k }.count * 5 >= col.count * 4 }) {
                score += headKinds[j] == .text ? 1 : -1
            } else if col.contains(h) {
                score -= 1
            } else if let len = col.first?.count, col.allSatisfy({ $0.count == len }), h.count != len {
                score += 1
            }
        }
        if Set(named).count < named.count { score -= 1 }
        if head.count - named.count > 1 { score -= 1 }
        return score >= 0
    }
}
