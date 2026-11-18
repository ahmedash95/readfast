import CReadFast

/// Sparse row index over the first `scanned` bytes of the data.
///
/// Per block of `blockSize` bytes it keeps the newlines before it and the scan
/// state at its start (RF_FIELD / RF_UNQUOTED / RF_QUOTED, see readfast.h):
/// ~1.4 MB for a 10 GB file at 64 KB blocks. Finding
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
    let stateAt: [UInt8]
    let endState: UInt8
    let delimiter: UInt8
    /// The row-ending byte: '\n', or '\r' for files with classic Mac line endings.
    let newline: UInt8

    var isComplete: Bool { scanned == total }
    var newlines: Int { cum[cum.count - 1] }

    /// Index the first `n` bytes, front to back in segments of `segmentBytes`
    /// (all cores inside each segment). After each segment `progress` gets the
    /// index so far: a valid partial index serving every row scanned yet.
    static func build(
        _ data: UnsafeRawBufferPointer, upTo n: Int, blockSize: Int, threads: Int,
        delimiter: UInt8 = UInt8(ascii: ","), newline: UInt8 = UInt8(ascii: "\n"), segmentBytes: Int = .max, progress: (RowIndex) -> Void = { _ in }
    ) -> RowIndex {
        precondition(blockSize > 0 && blockSize % 64 == 0, "blockSize must be a multiple of 64")
        precondition(n <= data.count)
        let segment = max(blockSize, segmentBytes / blockSize * blockSize) // whole blocks
        var cum = [0]
        var stateAt: [UInt8] = []
        cum.reserveCapacity((n + blockSize - 1) / blockSize + 1)
        stateAt.reserveCapacity(cum.capacity)
        var state = UInt8(RF_FIELD)
        var done = 0
        while true {
            let len = min(segment, n - done)
            let blocks = (len + blockSize - 1) / blockSize
            var counts = [UInt32](repeating: 0, count: blocks)
            var segStates = [UInt8](repeating: 0, count: blocks)
            if len > 0 {
                state = counts.withUnsafeMutableBufferPointer { c in
                    segStates.withUnsafeMutableBufferPointer { s in
                        rf_index(bytes(data) + done, len, blockSize, threads, delimiter, newline, state, c.baseAddress!, s.baseAddress!)
                    }
                }
            }
            for c in counts { cum.append(cum[cum.count - 1] + Int(c)) }
            stateAt += segStates
            done += len
            let idx = RowIndex(blockSize: blockSize, scanned: done, total: data.count, cum: cum, stateAt: stateAt,
                               endState: state, delimiter: delimiter, newline: newline)
            progress(idx)
            if done == n { return idx }
        }
    }

    /// Share of the file scanned, 0...1.
    var fraction: Double { total == 0 ? 1 : Double(scanned) / Double(total) }

    /// Exact row count. Only meaningful once complete. A final newline outside
    /// quotes ends the last row; it doesn't start another one.
    func exactRowCount(_ data: UnsafeRawBufferPointer) -> Int {
        guard total > 0 else { return 0 }
        let trailing = data[total - 1] == newline && endState != UInt8(RF_QUOTED)
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

    /// Byte range of row `r` without its newline (and a trailing '\r').
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
        let off = rf_find_newline(bytes(data) + start, min(blockSize, scanned - start), stateAt[b], delimiter, newline, UInt64(k - cum[b]))
        precondition(off >= 0, "index out of sync with data")
        return start + Int(off)
    }
}

func bytes(_ data: UnsafeRawBufferPointer) -> UnsafePointer<UInt8> {
    data.baseAddress!.assumingMemoryBound(to: UInt8.self)
}
