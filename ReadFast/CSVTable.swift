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

    private func refresh() {
        rowCount = max(0, file.rowCount.value - 1)
        isExact = file.isIndexed
        progress = file.indexedFraction
    }
}
