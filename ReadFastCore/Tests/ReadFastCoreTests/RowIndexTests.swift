import Testing
@testable import ReadFastCore

/// Row lookup through the sparse index, full and partial (preview).
struct RowIndexTests {
    @Test(arguments: [64, 128, 256], [1, 3, 8])
    func fullIndexMatchesOracle(blockSize: Int, threads: Int) {
        var rng = SplitMix(state: UInt64(blockSize + threads))
        for _ in 0..<200 {
            let d = randomBytes(Int.random(in: 0..<2000, using: &rng), &rng)
            let want = Oracle.rowRanges(d)
            withBuffer(d) { buf in
                let idx = RowIndex.build(buf, upTo: d.count, blockSize: blockSize, threads: threads)
                #expect(idx.isComplete)
                #expect(idx.rowCount(buf) == .exact(want.count))
                for (r, range) in want.enumerated() { #expect(idx.rowRange(r, buf) == range, "row \(r)") }
                #expect(idx.rowRange(want.count, buf) == nil)
                #expect(idx.rowRange(-1, buf) == nil)
            }
        }
    }

    /// A partial index serves exactly the rows that end inside the prefix, and
    /// they're the same rows the full index returns.
    @Test(arguments: [64, 128])
    func partialIndexServesRowsEndingInPrefix(blockSize: Int) {
        var rng = SplitMix(state: UInt64(blockSize))
        for _ in 0..<200 {
            let d = randomBytes(Int.random(in: 1..<2000, using: &rng), &rng)
            let prefix = min(d.count, blockSize * Int.random(in: 1...4, using: &rng))
            let want = Oracle.rowRanges(d)
            let ending = Oracle.newlines(d).filter { $0 < prefix }.count
            withBuffer(d) { buf in
                let idx = RowIndex.build(buf, upTo: prefix, blockSize: blockSize, threads: 1)
                #expect(idx.availableRows(buf) == (idx.isComplete ? want.count : ending))
                for r in 0..<idx.availableRows(buf) { #expect(idx.rowRange(r, buf) == want[r], "row \(r)") }
                #expect(idx.rowRange(idx.availableRows(buf), buf) == nil)
                if !idx.isComplete, case .exact = idx.rowCount(buf) { Issue.record("partial index claimed an exact count") }
            }
        }
    }

    /// Segmented build: same final index as one pass, and every intermediate
    /// index is a valid partial one, growing front to back.
    @Test(arguments: [64, 128, 320], [1, 3])
    func segmentedBuildGrowsFrontToBack(segmentBytes: Int, threads: Int) {
        var rng = SplitMix(state: UInt64(segmentBytes + threads))
        for _ in 0..<150 {
            let d = randomBytes(Int.random(in: 0..<2000, using: &rng), &rng)
            let want = Oracle.rowRanges(d)
            let nl = Oracle.newlines(d)
            withBuffer(d) { buf in
                var seen: [Int] = []
                let idx = RowIndex.build(buf, upTo: d.count, blockSize: 64, threads: threads, segmentBytes: segmentBytes) { partial in
                    seen.append(partial.scanned)
                    let rows = partial.availableRows(buf)
                    #expect(rows == (partial.isComplete ? want.count : nl.filter { $0 < partial.scanned }.count))
                    for r in 0..<rows { #expect(partial.rowRange(r, buf) == want[r]) }
                }
                var ends = [min(segmentBytes, d.count)]
                while ends.last! < d.count { ends.append(min(ends.last! + segmentBytes, d.count)) }
                #expect(seen == ends)
                #expect(idx.isComplete)
                #expect(idx.rowCount(buf) == .exact(want.count))
                #expect(idx.cum == RowIndex.build(buf, upTo: d.count, blockSize: 64, threads: threads).cum)
            }
        }
    }

    @Test func estimateIsExactForUniformRows() {
        let d = Array(String(repeating: "abc,def\n", count: 1000).utf8) // 8 bytes per row, 64 per block
        withBuffer(d) { buf in
            let idx = RowIndex.build(buf, upTo: 256, blockSize: 64, threads: 1)
            #expect(idx.rowCount(buf) == .estimated(1000))
        }
    }

    @Test(arguments: [
        ("", 0), ("a", 1), ("a\n", 1), ("a\nb", 2), ("a\nb\n", 2), ("a\r\nb\r\n", 2),
        ("\n", 1), ("\n\n", 2), ("x,\"b\nc\"\n", 1), ("x,\"unclosed\n", 1), ("\"\"\"\"\n1", 2),
    ])
    func edgeCases(text: String, rows: Int) {
        let d = Array(text.utf8)
        withBuffer(d) { buf in
            let idx = RowIndex.build(buf, upTo: d.count, blockSize: 64, threads: 1)
            #expect(idx.rowCount(buf) == .exact(rows))
            #expect(Oracle.rowRanges(d).count == rows) // the oracle agrees with the table
        }
    }

    @Test func crlfIsTrimmed() {
        let d = Array("id,v\r\n1,x\r\n".utf8)
        withBuffer(d) { buf in
            let idx = RowIndex.build(buf, upTo: d.count, blockSize: 64, threads: 1)
            #expect(idx.rowRange(0, buf) == 0..<4)
            #expect(idx.rowRange(1, buf) == 6..<9)
        }
    }

    @Test func indexMemoryIsSparse() {
        // 1 MB, 16 KB blocks: 64 blocks no matter how many rows
        let d = Array(String(repeating: "1,2\n", count: 1 << 18).utf8)
        withBuffer(d) { buf in
            let idx = RowIndex.build(buf, upTo: d.count, blockSize: 16 << 10, threads: 4)
            #expect(idx.cum.count == 65)
            #expect(idx.rowCount(buf) == .exact(1 << 18))
        }
    }
}
