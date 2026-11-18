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
    /// Column names: the header row, or "Column 1…" without one (and for columns wider than it).
    let header: [String]
    let url: URL
    /// What the user forced for this file (nil fields = detect).
    let options: CSVOptions
    /// What the engine detected for each setting, for "Automatic (…)" in the menu. For a forced
    /// setting it's carried over from the previous open, since the engine didn't detect it this time.
    let detected: CSVOptions
    var encoding: CSVEncoding { file.encoding }
    var delimiter: UInt8 { file.delimiter }
    var hasHeader: Bool { file.hasHeader }
    /// File size in bytes.
    let byteCount: Int
    /// Data rows (header excluded). Estimated until `isExact`.
    private(set) var rowCount = 0
    private(set) var isExact = false
    /// Share of the file indexed, 0...1.
    private(set) var progress = 0.0

    @ObservationIgnored private let file: CSVFile

    // MARK: Find

    /// Matches kept for highlighting and stepping, in file order (raw file rows: data row + 1 with a
    /// header, whose matches are dropped). ponytail: capped so "every row matches" can't eat memory; `searchTotal`
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

    /// Overrides chosen in the Format menu, per file, for this session (not persisted).
    static var sessionOptions: [URL: CSVOptions] = [:]

    /// Opens `url` with `options` (default: this session's overrides for it). `previous` is the
    /// table being replaced, whose detected values stand in for the settings now forced.
    static func load(_ url: URL, options: CSVOptions? = nil, previous: CSVTable? = nil) async throws -> CSVTable {
        let options = options ?? sessionOptions[url] ?? CSVOptions()
        sessionOptions[url] = options
        let file = try await open(url, options: options)
        return CSVTable(file: file, url: url, options: options, previousDetected: previous?.detected)
    }

    @concurrent nonisolated private static func open(_ url: URL, options: CSVOptions) async throws -> CSVFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // The mapping stays valid after access stops.
        return try CSVFile.open(url, encoding: options.encoding, delimiter: options.delimiter, hasHeader: options.hasHeader)
    }

    private init(file: CSVFile, url: URL, options: CSVOptions, previousDetected: CSVOptions?) {
        self.file = file
        self.url = url
        self.options = options
        detected = CSVOptions(encoding: options.encoding == nil ? file.encoding : previousDetected?.encoding,
                              delimiter: options.delimiter == nil ? file.delimiter : previousDetected?.delimiter,
                              hasHeader: options.hasHeader == nil ? file.hasHeader : previousDetected?.hasHeader)
        let previewRows = (0..<min(file.availableRows, Self.previewRows)).compactMap { file.row($0) }
        header = Self.columnNames(header: file.hasHeader ? previewRows.first : nil,
                                  width: previewRows.map(\.count).max() ?? 0)
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
        file.row(row + headerRows) ?? []
    }

    /// File rows before the first data row: 1 with a header, else 0.
    private var headerRows: Int { file.hasHeader ? 1 : 0 }

    /// Rows sampled for the column count, so header-less or ragged files show every column.
    static let previewRows = 100

    /// `header` padded with "Column N" up to `width` (all generated when there's no header).
    nonisolated static func columnNames(header: [String]?, width: Int) -> [String] {
        let header = header ?? []
        return header + (header.count..<max(width, header.count)).map { "Column \($0 + 1)" }
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
                if match.row < headerRows { headerMatches += 1 }
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
        return (matches[i].row - headerRows, matches[i].column)
    }

    /// Columns of data row `row` that match, and which of them is the current match.
    func matchedColumns(inRow row: Int) -> (columns: [Int], current: Int?) {
        guard !matches.isEmpty else { return ([], nil) }
        let fileRow = row + headerRows
        var i = Self.firstIndex(atOrAfter: fileRow, in: matches.lazy.map(\.row))
        var columns: [Int] = []
        var current: Int?
        while i < matches.count, matches[i].row == fileRow {
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
        assert(columnNames(header: ["a", "b"], width: 1) == ["a", "b"])
        assert(columnNames(header: ["a"], width: 3) == ["a", "Column 2", "Column 3"])
        assert(columnNames(header: nil, width: 2) == ["Column 1", "Column 2"])
        assert(columnNames(header: nil, width: 0).isEmpty)
        assert(delimiterName(UInt8(ascii: "\t")) == "Tab" && delimiterName(UInt8(ascii: ":")) == "“:”")
    }()
    #endif

    private func refresh() {
        rowCount = max(0, file.rowCount.value - headerRows)
        isExact = file.isIndexed
        progress = file.indexedFraction
    }
}

/// Format overrides for one file; nil = let the engine detect it.
struct CSVOptions: Hashable {
    var encoding: CSVEncoding?
    var delimiter: UInt8?
    var hasHeader: Bool?
}

extension CSVTable {
    static let delimiters: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "\t"), UInt8(ascii: "|")]

    nonisolated static func delimiterName(_ byte: UInt8) -> String {
        switch byte {
        case UInt8(ascii: ","): "Comma"
        case UInt8(ascii: ";"): "Semicolon"
        case UInt8(ascii: "\t"): "Tab"
        case UInt8(ascii: "|"): "Pipe"
        default: "“\(Character(Unicode.Scalar(byte)))”"
        }
    }
}

extension CSVEncoding {
    var name: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        case .windows1252: "Windows-1252"
        }
    }
}
