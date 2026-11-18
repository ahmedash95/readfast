import Testing
@testable import ReadFastCore

struct FieldsTests {
    func split(_ s: String, _ d: Character = ",") -> [String] {
        Array(s.utf8).withUnsafeBytes { Fields.split($0, delimiter: d.asciiValue!) }
    }

    @Test func plain() {
        #expect(split("a,b,c") == ["a", "b", "c"])
        #expect(split("a,,c") == ["a", "", "c"])
        #expect(split("a,") == ["a", ""])
        #expect(split("") == [""])
    }

    @Test func quotedAndEscaped() {
        #expect(split("7,\"Smith, J\",ok") == ["7", "Smith, J", "ok"])
        #expect(split("7,\"say \"\"hi\"\"\"") == ["7", "say \"hi\""])
        #expect(split("\"\"\"\"") == ["\""])
        #expect(split("\"\",x") == ["", "x"])
        #expect(split("\"two\nlines\",x") == ["two\nlines", "x"])
    }

    @Test func messyInputDoesNotCrash() {
        #expect(split("a,\"b,c") == ["a", "\"b,c"]) // unterminated quote: rest is one field
        #expect(split("5\" pipe,x") == ["5\" pipe,x"]) // stray quote opens a quote
        #expect(split("\"") == ["\""])
        #expect(split("caf\u{e9},\u{1F600}") == ["caf\u{e9}", "\u{1F600}"])
    }

    @Test func invalidUTF8BecomesReplacementCharacter() {
        let f = [UInt8(ascii: "a"), 0xFF].withUnsafeBytes { Fields.split($0, delimiter: UInt8(ascii: ",")) }
        #expect(f == ["a\u{FFFD}"])
    }

    @Test func otherDelimiters() {
        #expect(split("a;b;\"c;d\"", ";") == ["a", "b", "c;d"])
        #expect(split("a\tb", "\t") == ["a", "b"])
    }

    @Test(arguments: [("a,b,c", ","), ("a;b;c", ";"), ("a\tb", "\t"), ("a|b", "|"), ("\"x,y,z\";b", ";"), ("single", ","), ("a,b;c", ",")] as [(String, Character)])
    func sniff(row: String, want: Character) {
        let got = Array(row.utf8).withUnsafeBytes { Fields.sniffDelimiter($0) }
        #expect(got == want.asciiValue!)
    }
}
