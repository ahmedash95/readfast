import CReadFast
import Dispatch
import Foundation
import Synchronization

/// A cell whose displayed text contains the query. Same numbering as
/// `row(_:)`: row 0 is the first line; column = index into `row(row)`.
public struct SearchMatch: Hashable, Sendable {
    public let row: Int
    public let column: Int
}

/// One step of a search: the matches found since the previous step, in file order.
public struct SearchProgress: Sendable {
    public let matches: [SearchMatch]
    /// Share of the file scanned, 0...1.
    public let fraction: Double
    /// Matches found so far; on the last step, the total.
    public let total: Int
    /// The last step: the whole file was scanned.
    public let isComplete: Bool
}

extension CSVFile {
    /// Every cell whose displayed text (as `row(_:)` returns it) contains
    /// `query`, front to back on every core, streamed in file order.
    ///
    ///     for await step in file.search("smith") {
    ///         hits += step.matches   // grows as the scan goes
    ///         progress = step.fraction
    ///     }
    ///
    /// Stop by cancelling the consuming Task (or breaking out of the loop);
    /// the scan stops within one segment (a few ms). An empty query yields one
    /// complete step with no matches. `caseSensitive: false` folds ASCII only:
    /// `é` doesn't match `É`. Doesn't need `indexAll`: the search counts rows
    /// itself, so matches can be in rows `row(_:)` can't serve yet.
    ///
    /// Byte-based: works for UTF-8 and Windows-1252 (ASCII queries) files. For
    /// UTF-16 files `supportsSearch` is false and a search finishes at once with
    /// no matches; disable the search field for them.
    public func search(_ query: String, caseSensitive: Bool = false) -> AsyncStream<SearchProgress> {
        search(query, caseSensitive: caseSensitive, threads: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// `onSegment` gets the bytes scanned after each segment (tests use it to see cancellation).
    func search(
        _ query: String, caseSensitive: Bool, threads: Int, segmentBytes: Int = 16 << 20,
        onSegment: @escaping @Sendable (Int) -> Void = { _ in }
    ) -> AsyncStream<SearchProgress> {
        AsyncStream { out in
            let stopped = Stop()
            out.onTermination = { _ in stopped.flag.store(true, ordering: .relaxed) }
            DispatchQueue.global(qos: .userInitiated).async {
                var s = Searcher(file: self, query: query, fold: !caseSensitive)
                let n = self.data.count
                var done = s.query.isEmpty || !self.supportsSearch ? n : 0
                repeat {
                    if stopped.flag.load(ordering: .relaxed) { break }
                    let to = min(n, done + segmentBytes)
                    let matches = done < to ? s.scan(done, to, threads: threads) : []
                    done = to
                    onSegment(done)
                    out.yield(SearchProgress(matches: matches, fraction: n == 0 ? 1 : Double(done) / Double(n), total: s.total, isComplete: done == n))
                } while done < n
                out.finish()
            }
        }
    }
}

private final class Stop: Sendable { let flag = Atomic(false) }

/// The scan state across segments. C finds cells holding the query's longest
/// quote-free piece; when that can differ from "displayed text contains the
/// query" (the query has a quote, delimiter, '\n' or '\r'), each such cell is
/// unquoted with `Fields` and checked.
private struct Searcher {
    let file: CSVFile
    let query: [UInt8]   // lowercased when folding
    let fold: Bool
    let piece: [UInt8]
    let verify: Bool
    var state = rf_search_state(state: UInt8(RF_FIELD), rows: 0, row_start: 0, cell_start: 0, last_hit_cell: -1)
    var total = 0
    // column cursor: the last cell seen and its column
    var rowStart = -1, cellStart = 0, column = 0

    init(file: CSVFile, query: String, fold: Bool) {
        self.file = file
        self.fold = fold
        self.query = fold ? query.utf8.map(lowerASCII) : Array(query.utf8)
        let pieces = self.query.split(separator: Fields.quote)
        piece = pieces.isEmpty ? [Fields.quote] : Array(pieces.max { $0.count < $1.count }!)
        verify = self.query.contains { [Fields.quote, file.delimiter, UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains($0) }
    }

    mutating func scan(_ from: Int, _ to: Int, threads: Int) -> [SearchMatch] {
        var hits: UnsafeMutablePointer<rf_hit>?
        let n = rf_search(bytes(file.data), file.data.count, from, to, piece, piece.count, fold, file.delimiter, file.newline,
                          threads, &state, &hits)
        defer { free(hits) }
        var out: [SearchMatch] = []
        for h in UnsafeBufferPointer(start: hits, count: n) {
            let col = columnOf(cell: Int(h.cell), rowStart: Int(h.row_start))
            if verify || h.check, !cellMatches(Int(h.cell)) { continue }
            out.append(SearchMatch(row: Int(h.row), column: col))
        }
        total += out.count
        return out
    }

    /// readfast.h's quote rule, one byte at a time from a cell start (RF_FIELD).
    /// Whether `c` ends the cell: a delimiter or newline outside a quoted field.
    private func ends(_ state: inout UInt8, _ c: UInt8) -> Bool {
        if state == RF_QUOTED {
            if c == Fields.quote { state = UInt8(RF_FIELD) } // closed; a quote next is ""
            return false
        }
        if c == file.delimiter || c == file.newline { state = UInt8(RF_FIELD); return true }
        state = UInt8(c == Fields.quote && state == RF_FIELD ? RF_QUOTED : RF_UNQUOTED)
        return false
    }

    /// Walks forward from the last cell seen in the same row (hits come in
    /// file order), so a row is walked once however many cells match.
    private mutating func columnOf(cell: Int, rowStart rs: Int) -> Int {
        if rs != rowStart { rowStart = rs; cellStart = rs; column = 0 }
        let d = file.data
        var state = UInt8(RF_FIELD) // cellStart is a cell start
        for i in cellStart..<cell where ends(&state, d[i]) { column += 1 }
        cellStart = cell
        return column
    }

    /// Whether the cell's displayed text contains the query.
    private func cellMatches(_ cell: Int) -> Bool {
        let d = file.data
        var end = cell, state = UInt8(RF_FIELD)
        while end < d.count, !ends(&state, d[end]) { end += 1 }
        let rowEnd = end == d.count || d[end] == file.newline
        if rowEnd, end > cell, d[end - 1] == UInt8(ascii: "\r") { end -= 1 } // as rowRange trims it
        let text = Fields.split(UnsafeRawBufferPointer(rebasing: d[cell..<end]), delimiter: file.delimiter, encoding: file.encoding)[0]
        let shown = fold ? text.utf8.map(lowerASCII) : Array(text.utf8)
        return shown.firstRange(of: query) != nil
    }
}

private func lowerASCII(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c | 0x20 : c }

extension CSVFile {
    /// Whether `search` works for this file's encoding (not for UTF-16 yet).
    public var supportsSearch: Bool { encoding.unitWidth == 1 }
}
