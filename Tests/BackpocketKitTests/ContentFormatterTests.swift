import Testing

@testable import BackpocketKit

@Suite("ContentFormatter")
struct ContentFormatterTests {

    // MARK: kind(of:)

    @Test("Plain one-liner Korean text is plain")
    func koreanOneLinerIsPlain() {
        #expect(ContentFormatter.kind(of: "안녕하세요 오늘 회의는 3시입니다") == .plain)
    }

    @Test("Multi-line plain list is plain")
    func multiLinePlainListIsPlain() {
        let list = """
            사과
            바나나
            포도
            """
        #expect(ContentFormatter.kind(of: list) == .plain)
    }

    @Test("Indented multi-line text is code")
    func indentedMultiLineIsCode() {
        let snippet = """
            first line
                second line indented
            """
        #expect(ContentFormatter.kind(of: snippet) == .code)
    }

    @Test("Two lines of structure read as code, one does not")
    func twoStructuralLinesAreTheThreshold() {
        // Two is the whole rule, so both sides of it are pinned. One line
        // ending in a comma is an ordinary wrapped sentence — classifying
        // that as code would put prose in a monospaced face across the panel.
        #expect(ContentFormatter.kind(of: "alpha,\nbeta,") == .code)
        #expect(ContentFormatter.kind(of: "alpha,\nbeta") == .plain)
    }

    @Test("URL string is code")
    func urlIsCode() {
        #expect(ContentFormatter.kind(of: "https://example.com/path?q=1") == .code)
    }

    @Test("Single-line JSON is code")
    func singleLineJSONIsCode() {
        #expect(ContentFormatter.kind(of: #"{"name": "backpocket", "count": 3}"#) == .code)
    }

    @Test("Whitespace-only content is plain")
    func whitespaceOnlyIsPlain() {
        #expect(ContentFormatter.kind(of: "   \n\t  ") == .plain)
    }

    @Test("Empty string is plain")
    func emptyStringIsPlain() {
        #expect(ContentFormatter.kind(of: "") == .plain)
    }

    @Test("Single-line JSON array is code")
    func jsonArrayIsCode() {
        #expect(ContentFormatter.kind(of: #"[1, 2, 3]"#) == .code)
    }

    @Test("Tab-indented multi-line text is code")
    func tabIndentedMultiLineIsCode() {
        let snippet = "if ready {\n\tgo()\n}"
        #expect(ContentFormatter.kind(of: snippet) == .code)
    }

    // MARK: detail(of:)

    @Test("Single-line JSON is expanded with indentation")
    func singleLineJSONIsPrettyPrinted() {
        let detail = ContentFormatter.detail(of: #"{"name": "backpocket"}"#)
        let lines = detail.components(separatedBy: "\n")

        // Assert structure, not the exact serializer output — Foundation's
        // pretty-print separator has shifted between OS releases.
        #expect(lines.count == 3)
        #expect(lines.first == "{")
        #expect(lines.last == "}")
        #expect(lines[1].hasPrefix(" "))
        #expect(lines[1].contains(#""name""#))
        #expect(lines[1].contains(#""backpocket""#))
    }

    @Test("Single-line JSON array is expanded with indentation")
    func singleLineJSONArrayIsPrettyPrinted() {
        let detail = ContentFormatter.detail(of: "[1,2]")

        #expect(detail.contains("\n"))
        #expect(detail.hasPrefix("["))
        #expect(detail.hasSuffix("]"))
    }

    @Test("Already multi-line JSON is returned verbatim")
    func multiLineJSONIsVerbatim() {
        // Re-serializing would scramble key order ("zebra" before "apple"
        // here), so any transformation of this input is a regression.
        let json = """
            {
              "zebra": 1,
              "apple": 2
            }
            """
        #expect(ContentFormatter.detail(of: json) == json)
    }

    @Test("Common leading indentation is stripped, relative indentation kept")
    func commonIndentStrippedRelativeKept() {
        let indented = """
                func greet() {
                    print("hi")
                }
            """
        let expected = """
            func greet() {
                print("hi")
            }
            """
        #expect(ContentFormatter.detail(of: indented) == expected)
    }

    @Test("Common tab indentation is stripped, relative tabs kept")
    func tabIndentStrippedRelativeKept() {
        let indented = "\tif ready {\n\t\tgo()\n\t}"
        #expect(ContentFormatter.detail(of: indented) == "if ready {\n\tgo()\n}")
    }

    @Test("Text without common indentation is unchanged")
    func noCommonIndentIsUnchanged() {
        let text = "hello\n  world\nbye"
        #expect(ContentFormatter.detail(of: text) == text)
    }

    @Test("Empty string detail stays empty")
    func emptyStringDetailIsEmpty() {
        #expect(ContentFormatter.detail(of: "") == "")
    }

    @Test("Only code is set in a monospaced face")
    func onlyCodeIsMonospaced() {
        // The single question every row asks of the classification. Inverted,
        // every note and every copied sentence renders as code — which is the
        // one rendering choice a reader notices immediately.
        #expect(ContentKind.code.isMonospaced)
        #expect(!ContentKind.plain.isMonospaced)
    }
}
