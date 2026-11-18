import CReadFast

/// Sparse row index over the first `scanned` bytes of the data.
///
/// Per block of `blockSize` bytes it keeps the newlines before it and whether
/// it starts inside quotes: ~1.4 MB for a 10 GB file at 64 KB blocks. Finding
/// a row is a binary search plus a SIMD scan of at most one block.
///
/// A partial index (scanned < total) is what `open` builds from the first few
/// hundred KB; it serves every row that ends inside that prefix.
struct RowIndex: Sendable {
    let blockSize: Int
    let scanned: Int
    let total: Int
    /// cum[b] = row-ending newlines before block b; last element = all of them.
    let cum: [Int]
    let insideAt: [UInt8]
    let endsInside: Bool

    var isComplete: Bool { scanned == total }
    var newlines: Int { cum[cum.count - 1] }

    /// Index the first `n` bytes, front to back in segments of `segmentBytes`
    /// (all cores inside each segment). After each segment `progress` gets the
    /// index so far: a valid partial index serving every row scanned yet.
    static func build(
        _ data: UnsafeRawBufferPointer, upTo n: Int, blockSize: Int, threads: Int,
        segmentBytes: Int = .max, progress: (RowIndex) -> Void = { _ in }
    ) -> RowIndex {
        precondition(blockSize > 0 && blockSize % 64 == 0, "blockSize must be a multiple of 64")
        precondition(n <= data.count)
        let segment = max(blockSize, segmentBytes / blockSize * blockSize) // whole blocks
        var cum = [0]
        var insideAt: [UInt8] = []
        cum.reserveCapacity((n + blockSize - 1) / blockSize + 1)
        insideAt.reserveCapacity(cum.capacity)
        var inside = false
        var done = 0
        while true {
            let len = min(segment, n - done)
            let blocks = (len + blockSize - 1) / blockSize
            var counts = [UInt32](repeating: 0, count: blocks)
            var segInside = [UInt8](repeating: 0, count: blocks)
            if len > 0 {
                inside = counts.withUnsafeMutableBufferPointer { c in
                    segInside.withUnsafeMutableBufferPointer { i in
                        rf_index(bytes(data) + done, len, blockSize, threads, inside, c.baseAddress!, i.baseAddress!)
                    }
                }
            }
            for c in counts { cum.append(cum[cum.count - 1] + Int(c)) }
            insideAt += segInside
            done += len
            let idx = RowIndex(blockSize: blockSize, scanned: done, total: data.count, cum: cum, insideAt: insideAt, endsInside: inside)
            progress(idx)
            if done == n { return idx }
        }
    }

    /// Share of the file scanned, 0...1.
    var fraction: Double { total == 0 ? 1 : Double(scanned) / Double(total) }

    /// Exact row count. Only meaningful once complete. A final '\n' outside
    /// quotes ends the last row; it doesn't start another one.
    func exactRowCount(_ data: UnsafeRawBufferPointer) -> Int {
        guard total > 0 else { return 0 }
        let trailing = data[total - 1] == UInt8(ascii: "\n") && !endsInside
        return newlines + 1 - (trailing ? 1 : 0)
    }

    /// Rows that can be read right now: all of them once complete, otherwise
    /// the rows whose ending newline lies inside the scanned prefix.
    func availableRows(_ data: UnsafeRawBufferPointer) -> Int {
        isComplete ? exactRowCount(data) : newlines
    }

    /// Exact when complete, otherwise the prefix's rows-per-byte scaled to the file.
    func rowCount(_ data: UnsafeRawBufferPointer) -> RowCount {
        if isComplete { return .exact(exactRowCount(data)) }
        let scaled = Int(Double(newlines) * Double(total) / Double(max(scanned, 1)))
        return .estimated(max(scaled, newlines + 1))
    }

    /// Byte range of row `r` without its '\n' (and a trailing '\r').
    func rowRange(_ r: Int, _ data: UnsafeRawBufferPointer) -> Range<Int>? {
        guard r >= 0, r < availableRows(data) else { return nil }
        let start = r == 0 ? 0 : newlineOffset(r, data) + 1
        var end = r + 1 <= newlines ? newlineOffset(r + 1, data) : total
        if end > start, data[end - 1] == UInt8(ascii: "\r") { end -= 1 }
        return start..<end
    }

    /// Offset of the k-th (1-based) row-ending newline. k must be <= newlines.
    func newlineOffset(_ k: Int, _ data: UnsafeRawBufferPointer) -> Int {
        // first b + 1 with cum[b + 1] >= k: the k-th newline is in block b
        var lo = 1, hi = cum.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cum[mid] >= k { hi = mid } else { lo = mid + 1 }
        }
        let b = lo - 1
        let start = b * blockSize
        let off = rf_find_newline(bytes(data) + start, min(blockSize, scanned - start), insideAt[b] != 0, UInt64(k - cum[b]))
        precondition(off >= 0, "index out of sync with data")
        return start + Int(off)
    }
}

func bytes(_ data: UnsafeRawBufferPointer) -> UnsafePointer<UInt8> {
    data.baseAddress!.assumingMemoryBound(to: UInt8.self)
}
