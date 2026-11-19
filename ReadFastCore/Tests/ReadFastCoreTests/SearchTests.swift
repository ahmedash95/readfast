import Foundation
import Synchronization
import Testing
@testable import ReadFastCore

/// Find in file: cells whose displayed text contains the query, vs a scalar oracle.
struct SearchTests {
    /// Split every row with the oracle + Fields and keep the cells containing the query.
    static func oracle(_ d: [UInt8], _ query: String, delimiter: UInt8, newline: UInt8 = UInt8(ascii: "\n"),
                       caseSensitive: Bool) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        func fold(_ s: String) -> [UInt8] { s.utf8.map { caseSensitive ? $0 : (65...90).contains($0) ? $0 + 32 : $0 } }
        let q = fold(query)
        var out: [SearchMatch] = []
        for (r, range) in Oracle.rowRanges(d, delimiter: delimiter, newline: newline).enumerated() {
            let fields = Array(d[range]).withUnsafeBytes { Fields.split($0, delimiter: delimiter) }
            for (c, f) in fields.enumerated() {
                let h = fold(f)
                if h.count >= q.count, (0...(h.count - q.count)).contains(where: { Array(h[$0..<($0 + q.count)]) == q }) {
                    out.append(SearchMatch(row: r, column: c))
                }
            }
        }
        return out
    }

    static func run(_ f: CSVFile, _ q: String, caseSensitive: Bool = false, threads: Int = 1, segmentBytes: Int = 16 << 20) async -> (matches: [SearchMatch], steps: [SearchProgress]) {
        var steps: [SearchProgress] = []
        for await s in f.search(q, caseSensitive: caseSensitive, threads: threads, segmentBytes: segmentBytes) { steps.append(s) }
        return (steps.flatMap(\.matches), steps)
    }

    static func file(_ text: String, previewBytes: Int = 1 << 20) throws -> (CSVFile, URL) {
        let url = try tempFile(Array(text.utf8))
        return (try CSVFile(url: url, previewBytes: previewBytes, blockSize: 1024), url)
    }

    @Test(arguments: [1, 3, 8], [64, 192, 1000])
    func fuzzMatchesOracle(threads: Int, segmentBytes: Int) async throws {
        var rng = SplitMix(state: UInt64(threads * 1000 + segmentBytes))
        let alphabet = Array("aAbB,;\n\"\r")
        for trial in 0..<60 {
            // stray quotes everywhere; every 5th file has '\r' but no '\n' (classic Mac),
            // every 4th forces ';' (where a quote opens depends on the delimiter)
            let d = randomBytes(Int.random(in: 0..<1500, using: &rng), &rng,
                                alphabet: trial % 5 == 4 ? "aAbB,;;\r\r\"\" " : "aAbB,;;\n\n\"\"\r ")
            let url = try tempFile(d)
            defer { try? FileManager.default.removeItem(at: url) }
            let f = try CSVFile(url: url, previewBytes: 1024, blockSize: 1024,
                                delimiter: trial % 4 == 3 ? UInt8(ascii: ";") : nil)
            if trial % 5 == 4, d.contains(UInt8(ascii: "\r")) { #expect(f.newline == UInt8(ascii: "\r")) }
            await f.indexAll(threads: 2)
            for k in 0..<8 {
                let len = Int.random(in: 1...8, using: &rng)
                let q: String
                if k % 2 == 0, d.count >= len { // a piece of the data: likely to match
                    let s = Int.random(in: 0...(d.count - len), using: &rng)
                    q = String(decoding: d[s..<(s + len)], as: UTF8.self)
                } else {
                    q = String((0..<len).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
                }
                let cs = Bool.random(using: &rng)
                let got = await Self.run(f, q, caseSensitive: cs, threads: threads, segmentBytes: segmentBytes)
                let want = Self.oracle(d, q, delimiter: f.delimiter, newline: f.newline, caseSensitive: cs)
                #expect(got.matches == want, "trial \(trial) query \(q.debugDescription) cs \(cs)")
                for m in got.matches { // the cell row(_:) shows holds the query
                    let cell = f.row(m.row).flatMap { m.column < $0.count ? $0[m.column] : nil }
                    func fold(_ s: String) -> [UInt8] { s.utf8.map { cs ? $0 : (65...90).contains($0) ? $0 + 32 : $0 } }
                    #expect(cell.map { fold($0).firstRange(of: fold(q)) != nil } == true)
                }
                #expect(got.steps.last?.total == want.count)
                #expect(got.steps.last?.isComplete == true)
            }
        }
    }

    @Test func matchAtStartAndEnd() async throws {
        let (f, url) = try Self.file("abc,x\ny,ABC")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await Self.run(f, "abc").matches == [SearchMatch(row: 0, column: 0), SearchMatch(row: 1, column: 1)])
        #expect(await Self.run(f, "abc", caseSensitive: true).matches == [SearchMatch(row: 0, column: 0)])
    }

    /// The needle straddles a 64-byte block, a chunk (3 threads, 64-byte chunks)
    /// and a segment boundary, at every offset around 64.
    @Test(arguments: [(1, 1 << 20), (3, 192), (1, 64), (8, 64)])
    func needleAcrossBoundaries(threads: Int, segmentBytes: Int) async throws {
        for at in 56...64 {
            let text = String(repeating: "x", count: at) + "needle," + String(repeating: "y", count: 200)
            let (f, url) = try Self.file(text)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(await Self.run(f, "NEEDLE", threads: threads, segmentBytes: segmentBytes).matches == [SearchMatch(row: 0, column: 0)])
            #expect(await Self.run(f, "eedle,y", threads: threads, segmentBytes: segmentBytes).matches.isEmpty) // spans two cells
        }
    }

    @Test func quotedMultiLineFieldGivesItsRow() async throws {
        let (f, url) = try Self.file("h1,h2\n1,\"line one\nline two match\"\n2,match\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await Self.run(f, "match").matches == [SearchMatch(row: 1, column: 1), SearchMatch(row: 2, column: 1)])
        #expect(await Self.run(f, "one\nline").matches == [SearchMatch(row: 1, column: 1)])
        #expect(await Self.run(f, "1\n").matches.isEmpty) // a row end isn't text
    }

    @Test func quotesAndDelimitersInText() async throws {
        let (f, url) = try Self.file("a,\"say \"\"hi\"\"\",\"Smith, J\"\r\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await Self.run(f, "\"hi\"").matches == [SearchMatch(row: 0, column: 1)]) // "" is shown as "
        #expect(await Self.run(f, "y \"h").matches == [SearchMatch(row: 0, column: 1)])
        #expect(await Self.run(f, "\"\"").matches.isEmpty) // no cell shows two quotes in a row
        #expect(await Self.run(f, "\"say").matches.isEmpty) // the outer quotes aren't text
        #expect(await Self.run(f, "h, j").matches == [SearchMatch(row: 0, column: 2)])
        #expect(await Self.run(f, "a,").matches.isEmpty) // the delimiter isn't text
        #expect(await Self.run(f, "J\r").matches.isEmpty) // the trailing \r is trimmed
    }

    /// Search uses the index's quote rule: a stray quote doesn't hide the rows
    /// after it, and text after a closing quote is part of the shown cell.
    @Test func strayQuotesAndTextAfterClosingQuote() async throws {
        let (f, url) = try Self.file("id,size,note\n12,5\" pipe,ok\n13,\"ab\"cd,x\n14,y,pipe\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await Self.run(f, "pipe").matches == [SearchMatch(row: 1, column: 1), SearchMatch(row: 3, column: 2)])
        #expect(await Self.run(f, "5\" p").matches == [SearchMatch(row: 1, column: 1)])
        #expect(await Self.run(f, "bc").matches == [SearchMatch(row: 2, column: 1)]) // shown as abcd
        #expect(await Self.run(f, "b\"c").matches.isEmpty)
        #expect(f.row(2) == ["13", "abcd", "x"])
    }

    @Test func classicMacFile() async throws {
        let (f, url) = try Self.file("a,b\r1,\"x\ry\"\r2,y\r")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(f.newline == UInt8(ascii: "\r"))
        #expect(await Self.run(f, "y").matches == [SearchMatch(row: 1, column: 1), SearchMatch(row: 2, column: 1)])
        #expect(await Self.run(f, "x\ry").matches == [SearchMatch(row: 1, column: 1)])
    }

    @Test func noMatchesAndEmptyQuery() async throws {
        let (f, url) = try Self.file("a,b\nc,d\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let none = await Self.run(f, "zzz")
        #expect(none.matches.isEmpty)
        #expect(none.steps.last?.isComplete == true && none.steps.last?.total == 0 && none.steps.last?.fraction == 1)
        let empty = await Self.run(f, "")
        #expect(empty.steps.count == 1 && empty.matches.isEmpty && empty.steps[0].isComplete)
    }

    @Test func nonASCIIIsMatchedExactly() async throws {
        let (f, url) = try Self.file("caf\u{e9},CAF\u{c9}\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await Self.run(f, "caf\u{e9}").matches == [SearchMatch(row: 0, column: 0)]) // no folding beyond ASCII
        #expect(await Self.run(f, "CAF\u{c9}").matches == [SearchMatch(row: 0, column: 1)])
    }

    /// Many segments: matches arrive in file order, progress only grows.
    @Test func resultsArriveInFileOrder() async throws {
        var text = ""
        for i in 0..<3000 { text += i % 3 == 0 ? "\(i),hit,\"x\nhit\"\n" : "\(i),miss\n" }
        let (f, url) = try Self.file(text)
        defer { try? FileManager.default.removeItem(at: url) }
        let got = await Self.run(f, "hit", threads: 4, segmentBytes: 4096)
        #expect(got.steps.count > 5)
        #expect(got.steps.map(\.fraction) == got.steps.map(\.fraction).sorted())
        #expect(got.steps.map(\.total) == got.steps.map(\.total).sorted())
        #expect(got.matches.count == 2000)
        #expect(zip(got.matches, got.matches.dropFirst()).allSatisfy { ($0.row, $0.column) < ($1.row, $1.column) })
        #expect(f.row(got.matches.last!.row)?[got.matches.last!.column] == "x\nhit")
    }

    /// The search counts rows itself: no index past the preview needed.
    @Test func worksBeforeIndexAll() async throws {
        var text = "id,note\n"
        for i in 1...5000 { text += i % 7 == 0 ? "\(i),\"multi\nline, \"\"q\"\"\"\n" : "\(i),plain\n" }
        let (f, url) = try Self.file(text, previewBytes: 4096)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!f.isIndexed)
        let got = await Self.run(f, "\"q\"", threads: 4, segmentBytes: 8192)
        #expect(got.matches == Self.oracle(Array(text.utf8), "\"q\"", delimiter: f.delimiter, caseSensitive: false))
        #expect(got.matches.count == 714 && got.matches.last == SearchMatch(row: 4998, column: 1))
        #expect(!f.isIndexed)
        await f.indexAll(threads: 2)
        #expect(f.row(4998) == ["4998", "multi\nline, \"q\""])
    }

    @Test func cancellingTheTaskStopsTheScan() async throws {
        let text = String(repeating: "aaa,bbb,ccc\n", count: 1 << 20) // 12 MB, a match in every row
        let (f, url) = try Self.file(text)
        defer { try? FileManager.default.removeItem(at: url) }
        let scanned = Atomic(0)
        // The scan runs on its own thread, so how far it gets before the consumer is even
        // scheduled depends on the machine (busy CI runners got past half). What's promised:
        // once cancelled, it finishes at most the segment it's in.
        let segment = 64 << 10
        let atCancel = Atomic(0)
        let task = Task {
            for await _ in f.search("b", caseSensitive: false, threads: 1, segmentBytes: segment, onSegment: { scanned.store($0, ordering: .relaxed) }) {
                break // dropping the stream sets the stop flag (onTermination)
            }
            atCancel.store(scanned.load(ordering: .relaxed), ordering: .relaxed)
        }
        await task.value
        try await Task.sleep(for: .milliseconds(200))
        let stoppedAt = scanned.load(ordering: .relaxed)
        try await Task.sleep(for: .milliseconds(100))
        #expect(scanned.load(ordering: .relaxed) == stoppedAt) // not still running
        #expect(stoppedAt <= atCancel.load(ordering: .relaxed) + segment, "stopped at \(stoppedAt), cancelled at \(atCancel.load(ordering: .relaxed))")    }

    @Test func utf16FilesDontSupportSearchYet() async throws {
        let text = "id\tname\n1\tSmith\n"
        let url = try tempFile([0xFF, 0xFE] + Array(text.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try CSVFile.open(url)
        #expect(f.encoding == .utf16LE)
        #expect(!f.supportsSearch)
        var steps: [SearchProgress] = []
        for await step in f.search("Smith") { steps.append(step) }
        #expect(steps.count == 1 && steps[0].isComplete && steps[0].total == 0)
    }
}
