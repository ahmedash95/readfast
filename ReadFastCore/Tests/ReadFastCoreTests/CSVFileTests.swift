import Foundation
import Synchronization
import Testing
@testable import ReadFastCore

/// The public API end to end, on real mapped files.
struct CSVFileTests {
    @Test func smallFileIsCompleteOnOpen() throws {
        let url = try tempFile(Array("\u{FEFF}id;name\n1;\"Smith; J\"\n2;x\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try CSVFile.open(url)
        #expect(f.delimiter == UInt8(ascii: ";"))
        #expect(f.isIndexed)
        #expect(f.rowCount == .exact(3))
        #expect(f.row(0) == ["id", "name"]) // BOM stripped
        #expect(f.row(1) == ["1", "Smith; J"])
        #expect(f.row(2) == ["2", "x"])
        #expect(f.row(3) == nil)
    }

    @Test func emptyFile() throws {
        let url = try tempFile([])
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try CSVFile.open(url)
        #expect(f.rowCount == .exact(0))
        #expect(f.availableRows == 0)
        #expect(f.row(0) == nil)
    }

    @Test func missingFileThrows() {
        #expect(throws: POSIXError.self) { try CSVFile.open(URL(fileURLWithPath: "/nonexistent/x.csv")) }
    }

    /// Open shows a preview at once; indexAll upgrades to every row and an
    /// exact count. Tiny blocks make a 200 KB file behave like a big one.
    @Test func previewThenFullIndex() async throws {
        var text = "id,note\n"
        for i in 1...5000 { text += i % 7 == 0 ? "\(i),\"multi\nline, \"\"q\"\"\"\n" : "\(i),plain\n" }
        let url = try tempFile(Array(text.utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let f = try CSVFile(url: url, previewBytes: 4096, blockSize: 1024)
        #expect(!f.isIndexed)
        #expect(f.indexSnapshot.scanned == 4096) // nothing past the preview was scanned
        guard case .estimated(let guess) = f.rowCount else { Issue.record("expected an estimate"); return }
        #expect(abs(guess - 5001) < 500)
        let early = f.availableRows
        #expect(early > 100 && early < 5001)
        #expect(f.row(0) == ["id", "note"])
        #expect(f.row(early - 1) != nil)
        #expect(f.row(early) == nil) // not indexed yet

        // 16 KB segments over ~100 KB: rows and the estimate improve as each lands
        let log = Mutex<[(fraction: Double, rows: Int)]>([])
        await f.indexAll(threads: 4, segmentBytes: 16 << 10) { fraction in
            log.withLock { $0.append((fraction, f.availableRows)) }
        }
        let steps = log.withLock { $0 }
        #expect(steps.count > 3)
        #expect(steps.map(\.fraction) == steps.map(\.fraction).sorted())
        #expect(steps.map(\.rows) == steps.map(\.rows).sorted())
        #expect(steps.first!.rows > early)
        #expect(steps.last!.fraction == 1)
        #expect(f.indexedFraction == 1)
        #expect(f.isIndexed)
        #expect(f.rowCount == .exact(5001))
        #expect(f.row(7) == ["7", "multi\nline, \"q\""])
        #expect(f.row(5000) == ["5000", "plain"])
        #expect(f.row(5001) == nil)
        await f.indexAll() // no-op
        #expect(f.rowCount == .exact(5001))
    }

    /// A 4 GB sparse file: open must not read past the preview, so it's
    /// instant and uses no memory for the rest.
    @Test func hugeFileOpensWithoutReadingIt() throws {
        let head = Array("a,b\n1,2\n3,4\n".utf8)
        let url = try tempFile(head)
        defer { try? FileManager.default.removeItem(at: url) }
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: 4 << 30) // the rest is a hole: zeros, no disk
        try h.close()

        let clock = ContinuousClock()
        let start = clock.now
        let f = try CSVFile.open(url)
        let elapsed = clock.now - start

        #expect(elapsed < .milliseconds(200), "open took \(elapsed)")
        #expect(f.byteCount == 4 << 30)
        #expect(f.indexSnapshot.scanned == CSVFile.defaultPreviewBytes)
        #expect(f.row(0) == ["a", "b"])
        #expect(f.row(2)?.first == "3")
        #expect(!f.isIndexed)
    }

    @Test func runawayRowIsCut() async throws {
        // an unclosed quote swallows the rest of the file into one row
        let big = Array("h\n\"".utf8) + [UInt8](repeating: UInt8(ascii: "x"), count: 3 << 20)
        let url = try tempFile(big)
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try CSVFile(url: url, previewBytes: 1 << 20, blockSize: 64 << 10)
        await f.indexAll(threads: 2)
        #expect(f.rowCount == .exact(2))
        let row = try #require(f.row(1))
        #expect(row[0].utf8.count == CSVFile.maxRowBytes)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RF_BENCH"] != nil))
    func benchmark() async throws {
        // ~1 GB of CSV, warm in the page cache after writing
        let line = Array("12345,\"Smith, J\",2024-01-01,some text here,3.14159\n".utf8)
        var chunk: [UInt8] = []
        while chunk.count < 8 << 20 { chunk += line }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rf-bench.csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        for _ in 0..<128 { try h.write(contentsOf: Data(chunk)) }
        try h.close()
        defer { try? FileManager.default.removeItem(at: url) }

        let clock = ContinuousClock()
        var t = clock.now
        let f = try CSVFile.open(url)
        print("open: \(clock.now - t)")
        for threads in [1, ProcessInfo.processInfo.activeProcessorCount] {
            let g = try CSVFile.open(url)
            t = clock.now
            await g.indexAll(threads: threads)
            let s = Double((clock.now - t).components.attoseconds) / 1e18 + Double((clock.now - t).components.seconds)
            print("index \(threads) threads: \(String(format: "%.2f", Double(g.byteCount) / s / 1e9)) GB/s, \(g.rowCount)")
        }
        for (q, cs) in [("zebra", false), ("Smith", true), ("smith", false)] { // none, every row, every row
            t = clock.now
            var total = 0
            for await step in f.search(q, caseSensitive: cs) { total = step.total }
            let s = Double((clock.now - t).components.attoseconds) / 1e18 + Double((clock.now - t).components.seconds)
            print("search \(q.debugDescription) cs=\(cs): \(String(format: "%.2f", Double(f.byteCount) / s / 1e9)) GB/s, \(total) matches")
        }
        t = clock.now
        for i in stride(from: 0, to: f.availableRows, by: max(1, f.availableRows / 1000)) { _ = f.row(i) }
        print("1000 preview rows: \(clock.now - t)")

        // the same rows as ~1 GB of UTF-16 LE
        let wide = Data(utf16(String(decoding: chunk, as: UTF8.self), bigEndian: false, bom: true))
        let url16 = FileManager.default.temporaryDirectory.appendingPathComponent("rf-bench-16.csv")
        FileManager.default.createFile(atPath: url16.path, contents: nil)
        let h16 = try FileHandle(forWritingTo: url16)
        for _ in 0..<64 { try h16.write(contentsOf: wide) }
        try h16.close()
        defer { try? FileManager.default.removeItem(at: url16) }
        for threads in [1, ProcessInfo.processInfo.activeProcessorCount] {
            let g = try CSVFile.open(url16)
            t = clock.now
            await g.indexAll(threads: threads)
            let s = Double((clock.now - t).components.attoseconds) / 1e18 + Double((clock.now - t).components.seconds)
            print("utf16 index \(threads) threads: \(String(format: "%.2f", Double(g.byteCount) / s / 1e9)) GB/s, \(g.rowCount), \(g.encoding)")
        }
    }
}
