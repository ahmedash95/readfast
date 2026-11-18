import Foundation
import Observation
import ReadFastCore

/// The UI's view of one CSV file, backed by the ReadFastCore engine (see ReadFastCore/README.md).
///
/// `load` returns after mapping the file and indexing a 512 KB preview, so the header and first
/// rows show at once. `index()` then indexes the rest on every core, front to back: `rowCount`
/// grows from an estimate to the exact count and `progress` goes 0 → 1.
@MainActor @Observable
final class CSVTable {
    let header: [String]
    /// File size in bytes.
    let byteCount: Int
    /// Data rows (header excluded). Estimated until `isExact`.
    private(set) var rowCount = 0
    private(set) var isExact = false
    /// Share of the file indexed, 0...1.
    private(set) var progress = 0.0

    @ObservationIgnored private let file: CSVFile

    // MARK: Find

    /// Matches kept for highlighting and stepping, in file order (raw file rows: data row + 1, header
    /// matches dropped). ponytail: capped so "every row matches" can't eat memory; `searchTotal`
    /// still counts them all.
    static let maxStoredMatches = 1_000_000
    @ObservationIgnored private(set) var matches: [SearchMatch] = []
    /// Matches in data rows found so far (all of them once the search completes).
    private(set) var searchTotal = 0
    private(set) var isSearching = false
    /// Index into `matches` of the match Find Next/Previous last went to.
    private(set) var currentMatch: Int?
    /// Bumped on every change to `matches` or `currentMatch`, so the grid knows to redraw.
    private(set) var searchVersion = 0
    var supportsSearch: Bool { file.supportsSearch }

    static func load(_ url: URL) async throws -> CSVTable {
        CSVTable(file: try await open(url))
    }

    @concurrent nonisolated private static func open(_ url: URL) async throws -> CSVFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try CSVFile.open(url) // the mapping stays valid after access stops
    }

    private init(file: CSVFile) {
        self.file = file
        header = file.row(0) ?? []
        byteCount = file.byteCount
        refresh()
        #if DEBUG
        Self.selfCheck
        #endif
    }

    /// Index the whole file in the background. Returns once the row count is exact.
    func index() async {
        await file.indexAll { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    /// Fields of data row `row` (0-based, header excluded). Empty while that row isn't indexed
    /// yet; a real row always has at least one field.
    func fields(at row: Int) -> [String] {
        file.row(row + 1) ?? []
    }

    /// Replace the matches with those of `query`, accumulating as the scan streams. Cancel the
    /// calling Task to stop it (a new query does that via `.task(id:)`).
    func search(_ query: String) async {
        matches = []
        searchTotal = 0
        currentMatch = nil
        searchVersion += 1
        isSearching = !query.isEmpty
        guard isSearching else { return }
        var headerMatches = 0
        for await step in file.search(query) {
            if Task.isCancelled { return }
            for match in step.matches {
                if match.row == 0 { headerMatches += 1 }
                else if matches.count < Self.maxStoredMatches { matches.append(match) }
            }
            searchTotal = step.total - headerMatches
            searchVersion += 1
        }
        if !Task.isCancelled { isSearching = false }
    }

    /// Moves to the next (`delta` 1) or previous (-1) match, wrapping; returns it as (data row, column).
    func stepMatch(by delta: Int) -> (row: Int, column: Int)? {
        guard let i = Self.step(currentMatch, by: delta, count: matches.count) else { return nil }
        currentMatch = i
        searchVersion += 1
        return (matches[i].row - 1, matches[i].column)
    }

    /// Columns of data row `row` that match, and which of them is the current match.
    func matchedColumns(inRow row: Int) -> (columns: [Int], current: Int?) {
        guard !matches.isEmpty else { return ([], nil) }
        var i = Self.firstIndex(atOrAfter: row + 1, in: matches.lazy.map(\.row))
        var columns: [Int] = []
        var current: Int?
        while i < matches.count, matches[i].row == row + 1 {
            columns.append(matches[i].column)
            if i == currentMatch { current = matches[i].column }
            i += 1
        }
        return (columns, current)
    }

    /// Binary search: index of the first element >= `value` in ascending `sorted`.
    nonisolated static func firstIndex(atOrAfter value: Int, in sorted: some RandomAccessCollection<Int>) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[sorted.index(sorted.startIndex, offsetBy: mid)] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Next/previous index with wraparound; from no current match, next is the first, previous the last.
    nonisolated static func step(_ current: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta > 0 ? 0 : count - 1 }
        return ((current + delta) % count + count) % count
    }

    #if DEBUG
    nonisolated static let selfCheck: Void = {
        assert(firstIndex(atOrAfter: 3, in: [1, 3, 3, 5]) == 1)
        assert(firstIndex(atOrAfter: 4, in: [1, 3, 3, 5]) == 3)
        assert(firstIndex(atOrAfter: 9, in: [1, 3, 3, 5]) == 4)
        assert(firstIndex(atOrAfter: 0, in: [Int]()) == 0)
        assert(step(nil, by: 1, count: 3) == 0 && step(nil, by: -1, count: 3) == 2)
        assert(step(2, by: 1, count: 3) == 0 && step(0, by: -1, count: 3) == 2)
        assert(step(nil, by: 1, count: 0) == nil)
    }()
    #endif

    private func refresh() {
        rowCount = max(0, file.rowCount.value - 1)
        isExact = file.isIndexed
        progress = file.indexedFraction
    }
}
