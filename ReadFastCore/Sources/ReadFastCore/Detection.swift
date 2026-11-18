/// Delimiter and header sniffing over a handful of preview rows. Scalar: it
/// runs once per `open`, on at most `sampleRows` rows of `sampleRowBytes` each.
///
/// Not candidates: ':' (times like 12:30:00 split every row the same way) and
/// ' ' (prose splits into a consistent-looking word count). Both would win
/// over the real delimiter on ordinary files.
extension Fields {
    static let sampleRows = 50
    static let sampleRowBytes = 64 << 10
    static let delimiterCandidates: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "\t"), UInt8(ascii: "|")]

    /// The candidate whose field count is the same on the most rows (that count
    /// must be > 1), then the one with more fields, then candidate order.
    /// A title line, ragged rows and quoted delimiters don't sway it. A comma
    /// that only ever sits between digits (`1,5;2,7`) is a decimal comma: ';'
    /// wins any tie with it. Nothing fits (one column, empty): ','.
    static func sniffDelimiter(_ rows: [UnsafeRawBufferPointer]) -> UInt8 {
        let cands = delimiterCandidates
        var counts = [[Int: Int]](repeating: [:], count: cands.count) // fields per row -> rows
        var decimalCommas = true
        for row in rows {
            var n = [Int](repeating: 1, count: cands.count)
            var inside = false
            for i in 0..<row.count {
                let c = row[i]
                if c == quote { inside.toggle(); continue }
                if inside { continue }
                guard let k = cands.firstIndex(of: c) else { continue }
                n[k] += 1
                if k == 0, !(i > 0 && i + 1 < row.count && isDigit(row[i - 1]) && isDigit(row[i + 1])) { decimalCommas = false }
            }
            for k in cands.indices { counts[k][n[k], default: 0] += 1 }
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

    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

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
