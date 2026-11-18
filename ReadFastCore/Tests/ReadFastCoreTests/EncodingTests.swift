import CReadFast
import Foundation
import Testing
@testable import ReadFastCore

func utf16(_ s: String, bigEndian: Bool, bom: Bool = false) -> [UInt8] {
    let units = (bom ? [0xFEFF] : []) + Array(s.utf16)
    return units.flatMap { u in bigEndian ? [UInt8(u >> 8), UInt8(u & 0xFF)] : [UInt8(u & 0xFF), UInt8(u >> 8)] }
}

func cp1252(_ s: String) -> [UInt8] { Array(s.data(using: .windowsCP1252)!) }

func withFile<R>(_ bytes: [UInt8], _ body: (URL) async throws -> R) async throws -> R {
    let url = try tempFile(bytes)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

struct EncodingTests {
    @Test(arguments: [
        (Array("\u{FEFF}a,b\n1,\u{e9}\n".utf8), CSVEncoding.utf8, ","),
        (utf16("a\tb\n1\t\u{e9}\n", bigEndian: false, bom: true), .utf16LE, "\t"),
        (utf16("a\tb\n1\t\u{e9}\n", bigEndian: true, bom: true), .utf16BE, "\t"),
        (utf16("a,b\n1,\u{e9}\n", bigEndian: false), .utf16LE, ","),
        (utf16("a;b\n1;\u{e9}\n", bigEndian: true), .utf16BE, ";"),
        (Array("a,b\n1,\u{e9}\n".utf8), .utf8, ","),
        (cp1252("a,b\n1,\u{e9}\n"), .windows1252, ","),
    ] as [([UInt8], CSVEncoding, Character)])
    func detectsAndDecodes(bytes: [UInt8], want: CSVEncoding, delimiter: Character) async throws {
        try await withFile(bytes) { url in
            let f = try CSVFile.open(url)
            #expect(f.encoding == want)
            #expect(f.delimiter == delimiter.asciiValue!)
            #expect(f.rowCount == .exact(2))
            #expect(f.row(0) == ["a", "b"]) // BOM skipped
            #expect(f.row(1) == ["1", "\u{e9}"])
        }
    }

    @Test func detectsMore() async throws {
        let cases: [([UInt8], CSVEncoding)] = [
            (Array("id,name\n1,\u{65E5}\u{672C}\u{1F600}\n".utf8), .utf8),
            (cp1252("id,name\n1,caf\u{e9} \u{20AC}5 \u{201C}q\u{201D} \u{2019}\n"), .windows1252),
            (Array("id,name\n1,x\n".utf8), .utf8),
            ([], .utf8),
        ]
        for (bytes, want) in cases {
            let got = try await withFile(bytes) { try CSVFile.open($0).encoding }
            #expect(got == want)
        }
        // a sample that ends mid-character is still UTF-8
        try await withFile(Array("a,\u{e9}\nx\n".utf8)) { url in
            let f = try CSVFile.open(url, previewBytes: 3) // "a,\u{C3}"
            #expect(f.encoding == .utf8)
        }
        let w = try await withFile(cp1252("n\ncaf\u{e9} \u{20AC}5 \u{201C}q\u{201D}\n")) { try CSVFile.open($0).row(1) }
        #expect(w == ["caf\u{e9} \u{20AC}5 \u{201C}q\u{201D}"])
    }

    @Test func overrideWinsOverDetection() async throws {
        try await withFile(Array("n\ncaf\u{e9}\n".utf8)) { url in
            let f = try CSVFile.open(url, encoding: .windows1252)
            #expect(f.encoding == .windows1252)
            #expect(f.row(1) == ["caf\u{C3}\u{A9}"])
        }
        // BOM-less all-CJK UTF-16 has no zero bytes to detect; the override reads it
        let cjk = utf16("\u{65E5}\u{672C},\u{4E2D}\n\u{6587},\u{5B57}\n", bigEndian: false)
        try await withFile(cjk) { url in
            let detected = try CSVFile.open(url).encoding
            #expect(detected != .utf16LE)
            let f = try CSVFile.open(url, encoding: .utf16LE)
            #expect(f.row(0) == ["\u{65E5}\u{672C}", "\u{4E2D}"])
            #expect(f.row(1) == ["\u{6587}", "\u{5B57}"])
        }
    }

    @Test func windows1252TableMatchesFoundation() {
        for b in 0...255 where ![0x81, 0x8D, 0x8F, 0x90, 0x9D].contains(b) {
            let got = [UInt8(b)].withUnsafeBytes { Windows1252.decode($0) }
            #expect(got == String(data: Data([UInt8(b)]), encoding: .windowsCP1252), "byte \(b)")
        }
    }

    @Test func utf8ValidatorMatchesSwift() {
        var rng = SplitMix(state: 8)
        let alphabet: [UInt8] = [0x61, 0x2C, 0x00, 0x7F, 0x80, 0xBF, 0xC0, 0xC2, 0xDF, 0xE0, 0xA0, 0x9F, 0xED, 0xEF, 0xF0, 0x90, 0x8F, 0xF4, 0xF5, 0xFF]
        for _ in 0..<5000 {
            let n = Int.random(in: 0..<40, using: &rng)
            // long ASCII prefix exercises the SIMD skip
            let d = [UInt8](repeating: 0x61, count: Int.random(in: 0..<40, using: &rng))
                + (0..<n).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }
            #expect(rf_utf8_valid(d, d.count, false) == (String(validating: d, as: UTF8.self) != nil), "\(d)")
        }
        let cut = Array("a\u{1F600}".utf8).dropLast()
        #expect(rf_utf8_valid(Array(cut), cut.count, true))
        #expect(!rf_utf8_valid(Array(cut), cut.count, false))
    }

    @Test func eqMask16MatchesScalar() {
        var rng = SplitMix(state: 16)
        for _ in 0..<1000 {
            let b = randomBytes(128, &rng, alphabet: "\0\",\n\u{22}")
            for c: UInt16 in [0x0022, 0x2200, 0x000A, 0x0A00, 0] {
                var want: UInt64 = 0
                for i in 0..<64 where UInt16(b[2 * i]) | UInt16(b[2 * i + 1]) << 8 == c { want |= 1 << UInt64(i) }
                #expect(rf_eq_mask16(b, c) == want)
            }
        }
    }

    /// Random CSV text in every encoding gives the same rows as UTF-8, through
    /// preview, segmented parallel indexing and field splitting. The alphabet
    /// has quotes, quoted newlines, CRLF, non-ASCII and UTF-16 units whose bytes
    /// are '"', ',' or '\n' (U+220A, U+0A22, U+2C22) to catch byte-level scanning.
    @Test(arguments: [(128, 1, 256), (256, 3, 512), (128, 8, 384), (1024, 2, 1 << 20)] as [(Int, Int, Int)])
    func roundTripMatchesUTF8(blockSize: Int, threads: Int, segmentBytes: Int) async throws {
        let common = ["a", "b", "1", ",", ",", "\n", "\n", "\"", "\"", "\r\n", "\u{e9}", "\u{20AC}", "\u{2019}"]
        let wide = ["\u{220A}", "\u{0A22}", "\u{2C22}", "\u{65E5}", "\u{1F600}"]
        var rng = SplitMix(state: UInt64(blockSize * 7 + threads))
        for trial in 0..<60 {
            let only1252 = trial % 3 == 0
            let alphabet = only1252 ? common : common + wide
            let text = (0..<Int.random(in: 0..<800, using: &rng)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }.joined()

            let want = try await rows(Array(text.utf8), .utf8, blockSize, threads, segmentBytes)
            var variants: [(CSVEncoding, [UInt8])] = [
                (.utf16LE, utf16(text, bigEndian: false, bom: trial % 2 == 0)),
                (.utf16BE, utf16(text, bigEndian: true, bom: trial % 2 == 0)),
            ]
            if only1252 { variants.append((.windows1252, cp1252(text))) }
            for (enc, bytes) in variants {
                let got = try await rows(bytes, enc, blockSize, threads, segmentBytes)
                #expect(got == want, "\(enc) trial \(trial)")
            }
        }
    }

    /// Opens with a 2-block preview, checks preview rows against the full read, then indexes.
    private func rows(_ bytes: [UInt8], _ enc: CSVEncoding, _ blockSize: Int, _ threads: Int, _ segmentBytes: Int) async throws -> [[String]] {
        try await withFile(bytes) { url in
            let f = try CSVFile(url: url, previewBytes: 2 * blockSize, blockSize: blockSize, encoding: enc)
            let preview = (0..<f.availableRows).map { f.row($0)! }
            await f.indexAll(threads: threads, segmentBytes: segmentBytes)
            let all = (0..<f.rowCount.value).map { f.row($0)! }
            #expect(f.row(all.count) == nil)
            #expect(Array(all.prefix(preview.count)) == preview)
            return all
        }
    }

    /// Excel "Unicode text": UTF-16 LE with BOM, tab-separated, bigger than the preview.
    @Test(arguments: [false, true])
    func utf16PreviewThenFullIndex(bigEndian: Bool) async throws {
        var text = "id\tnote\n"
        for i in 1...5000 { text += i % 7 == 0 ? "\(i)\t\"multi\nline\t \"\"q\"\" \u{e9}\u{1F600}\"\r\n" : "\(i)\tplain\u{20AC}\r\n" }
        try await withFile(utf16(text, bigEndian: bigEndian, bom: true)) { url in
            let f = try CSVFile(url: url, previewBytes: 4096, blockSize: 1024)
            #expect(f.encoding == (bigEndian ? .utf16BE : .utf16LE))
            #expect(f.delimiter == UInt8(ascii: "\t"))
            #expect(!f.isIndexed)
            let early = f.availableRows
            #expect(early > 50 && early < 5001)
            #expect(f.row(0) == ["id", "note"])
            #expect(f.row(early - 1) != nil)
            #expect(f.row(early) == nil)
            await f.indexAll(threads: 4, segmentBytes: 16 << 10)
            #expect(f.rowCount == .exact(5001))
            #expect(f.row(7) == ["7", "multi\nline\t \"q\" \u{e9}\u{1F600}"])
            #expect(f.row(5000) == ["5000", "plain\u{20AC}"])
            #expect(f.row(5001) == nil)
        }
    }

    /// RowIndexTests.strayQuoteAtEveryOffset in UTF-16: one stray quote at every
    /// offset (on and around block, chunk and segment boundaries) gives the same
    /// rows as UTF-8, and UTF-8 gives the oracle's. U+220A / U+2C22 have a '"' / ','
    /// byte, so a byte-level slip shows up.
    @Test(arguments: [1, 2, 3, 8])
    func strayQuoteAtEveryOffsetUTF16(threads: Int) {
        let clean = Array(String(repeating: "123,\u{e9}\u{220A}\u{2C22},\"q,x\"\n", count: 30))
        for at in 0...clean.count {
            var chars = clean
            chars.insert("\"", at: at)
            let text = String(chars)
            let d = Array(text.utf8)
            let want = Oracle.rowRanges(d).map { r in Array(d[r]).withUnsafeBytes { Fields.split($0, delimiter: 44) } }
            #expect(indexedRows(d, .utf8, threads) == want, "quote at \(at)")
            for be in [false, true] {
                #expect(indexedRows(utf16(text, bigEndian: be), be ? .utf16BE : .utf16LE, threads) == want, "quote at \(at), BE \(be)")
            }
        }
    }

    /// A delimiter then a quote, slid across every unit offset of quote-free
    /// blocks: the state carried out of a block with no quotes (field start vs
    /// unquoted) decides whether the next block's quote opens a field.
    @Test(arguments: [1, 3])
    func quoteAfterDelimiterAtEveryBlockOffset(threads: Int) {
        for pad in 0..<200 {
            let text = String(repeating: "x", count: pad) + ",\"a\nb\",c\n" + String(repeating: "y", count: 130) + "\"\n,\"d\ne\"\n"
            let d = Array(text.utf8)
            let want = Oracle.rowRanges(d).map { r in Array(d[r]).withUnsafeBytes { Fields.split($0, delimiter: 44) } }
            #expect(want.count == 3)
            #expect(indexedRows(d, .utf8, threads) == want, "pad \(pad)")
            for be in [false, true] {
                #expect(indexedRows(utf16(text, bigEndian: be), be ? .utf16BE : .utf16LE, threads) == want, "pad \(pad), BE \(be)")
            }
        }
    }

    /// Rows through a segmented parallel RowIndex: 128-byte blocks, 3-block segments.
    private func indexedRows(_ d: [UInt8], _ enc: CSVEncoding, _ threads: Int) -> [[String]] {
        withBuffer(d) { buf in
            let idx = RowIndex.build(buf, upTo: d.count, blockSize: 128, threads: threads, encoding: enc, segmentBytes: 384)
            return (0..<idx.rowCount(buf).value).map { r in
                Fields.split(UnsafeRawBufferPointer(rebasing: buf[idx.rowRange(r, buf)!]), delimiter: 44, encoding: enc)
            }
        }
    }

    /// Classic Mac line endings ('\r' only) in UTF-16, bigger than the preview.
    @Test(arguments: [false, true])
    func classicMacUTF16(bigEndian: Bool) async throws {
        var text = "id;note\r"
        for i in 1...1500 { text += i % 3 == 0 ? "\(i);\"two\rlines\n\u{e9}\"\r" : "\(i);x\u{20AC}\r" }
        try await withFile(utf16(text, bigEndian: bigEndian, bom: true)) { url in
            let f = try CSVFile(url: url, previewBytes: 2048, blockSize: 256)
            #expect(f.encoding == (bigEndian ? .utf16BE : .utf16LE))
            #expect(f.newline == UInt8(ascii: "\r"))
            #expect(f.delimiter == UInt8(ascii: ";"))
            #expect(f.row(0) == ["id", "note"])
            await f.indexAll(threads: 3, segmentBytes: 1024)
            #expect(f.rowCount == .exact(1501))
            for i in 1...1500 { #expect(f.row(i) == ["\(i)", i % 3 == 0 ? "two\rlines\n\u{e9}" : "x\u{20AC}"], "row \(i)") }
        }
    }
}
