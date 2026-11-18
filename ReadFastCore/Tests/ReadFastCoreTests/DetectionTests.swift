import Foundation
import Testing
@testable import ReadFastCore

/// Delimiter and header detection, through `CSVFile.open` on real files so the
/// preview sampling is exercised too.
struct DetectionTests {
    func open(_ text: String, delimiter: UInt8? = nil, hasHeader: Bool? = nil) throws -> CSVFile {
        let url = try tempFile(Array(text.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        return try CSVFile.open(url, delimiter: delimiter, hasHeader: hasHeader)
    }

    static let delimiterCases: [(name: String, text: String, want: Character)] = [
        ("comma", "a,b,c\n1,2,3\n4,5,6\n", ","),
        ("semicolon", "a;b;c\n1;2;3\n", ";"),
        ("tab", "a\tb\tc\n1\t2\t3\n", "\t"),
        ("pipe", "a|b|c\n1|2|3\n", "|"),
        ("title line", "Sales report; Q1, 2024\nid|name|amount\n1|x|2\n2|y|3\n3|z|4\n", "|"),
        ("comment line", "# exported by tool v2; do not edit\nid,name\n1,x\n2,y\n", ","),
        ("one column", "name\nSmith, J\nDoe\nRoe\n", ","),
        ("quoted other delimiters", "id;note\n1;\"a,b,c,d\"\n2;\"e,f,g,h\"\n", ";"),
        ("quoted same-count trap", "\"a;b;c\",x\n\"d;e;f\",y\n\"g;h;i\",z\n", ","),
        ("ragged", "a,b,c\n1,2\n3,4,5\n6,7,8\n9\n10,11,12,13\n", ","),
        ("decimal commas with header", "x;y\n1,5;2,7\n3,1;4,2\n", ";"),
        ("decimal commas, no header", "1,5;2,7\n3,1;4,2\n5,0;6,9\n", ";"),
        ("tab with commas in text", "name\tnote\nbob\thello, world\nal\tx, y, z\ncy\tplain\n", "\t"),
        ("few rows", "a|b\n", "|"),
        ("empty", "", ","),
        ("blank lines only", "\n\n\n", ","),
    ]

    @Test(arguments: delimiterCases)
    func delimiter(_ c: (name: String, text: String, want: Character)) throws {
        #expect(try open(c.text).delimiter == c.want.asciiValue!, "\(c.name)")
    }

    @Test func singleHugeRowWithoutNewlineInPreview() throws {
        let row = (0..<200_000).map { "f\($0)" }.joined(separator: ";") // ~1.3 MB, no newline
        let f = try open(row + "\n1;2\n")
        #expect(f.delimiter == UInt8(ascii: ";"))
        #expect(f.availableRows == 0)
    }

    static let headerCases: [(name: String, text: String, want: Bool)] = [
        ("header + numeric data", "id,price,qty\n1,9.99,3\n2,19.5,1\n3,0.5,10\n", true),
        ("all-text table with header", "name,city,color\nalice,london,red\nbob,paris,blue\ncarol,rome,green\n", true),
        ("all-text table without header", "red,small,yes\nblue,large,no\nred,large,yes\ngreen,small,no\n", false),
        ("numeric only", "1,2,3\n4,5,6\n7,8,9\n", false),
        ("decimal commas, numeric only", "1,5;2,7\n3,1;4,2\n", false),
        ("duplicate names, text data", "a,a,b\nc,d,e\nf,g,h\n", false),
        ("duplicate names, numeric data", "x,x,y\n1,2,3\n4,5,6\n", true),
        ("empty names", ",,\na,b,c\nd,e,f\n", false),
        ("index column (one empty name)", ",a,b\n0,1,2\n1,3,4\n", true),
        ("date column", "date,value\n2024-01-01,3\n2024-01-02,4\n", true),
        ("dates without header", "2024-01-01,3\n2024-01-02,4\n2024-01-03,5\n", false),
        ("fixed-length codes", "code,name\nAB12,x\nCD34,x2\nEF56,y\n", true),
        ("single row, names", "id,name,email\n", true),
        ("single row, numbers", "1,2,3\n", false),
        ("empty file", "", false),
    ]

    @Test(arguments: headerCases)
    func header(_ c: (name: String, text: String, want: Bool)) throws {
        #expect(try open(c.text).hasHeader == c.want, "\(c.name)")
    }

    @Test func overridesWin() throws {
        let f = try open("a;b\n1;2\n", delimiter: UInt8(ascii: ","), hasHeader: false)
        #expect(f.delimiter == UInt8(ascii: ","))
        #expect(!f.hasHeader)
        #expect(f.row(0) == ["a;b"])
        let g = try open("1,2\n3,4\n", delimiter: UInt8(ascii: "|"), hasHeader: true)
        #expect(g.hasHeader)
        #expect(g.row(1) == ["3,4"])
        // only one forced: the other is still detected (with the forced delimiter)
        #expect(try open("1;2\n3;4\n", delimiter: UInt8(ascii: ";")).hasHeader == false)
        #expect(try open("1;2\n3;4\n", hasHeader: true).delimiter == UInt8(ascii: ";"))
    }

    @Test func randomInputNeverCrashesAndReturnsACandidate() throws {
        var rng = SplitMix(state: 42)
        for _ in 0..<300 {
            let bytes = randomBytes(Int.random(in: 0..<400, using: &rng), &rng, alphabet: "a1.,;\t| \n\n\"\r-:")
            let rows = Oracle.rowRanges(bytes)
            let d = bytes.withUnsafeBytes { all in Fields.sniffDelimiter(rows.map { UnsafeRawBufferPointer(rebasing: all[$0]) }) }
            #expect(Fields.delimiterCandidates.contains(d))
            _ = bytes.withUnsafeBytes { all in Fields.detectHeader(rows.map { Fields.split(UnsafeRawBufferPointer(rebasing: all[$0]), delimiter: d) }) }
        }
        let url = try tempFile(randomBytes(5000, &rng, alphabet: "a1,;\t|\n\""))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Fields.delimiterCandidates.contains(try CSVFile(url: url, previewBytes: 1024, blockSize: 256).delimiter))
    }
}
