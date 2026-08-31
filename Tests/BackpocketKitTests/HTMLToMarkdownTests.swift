import Foundation
import Testing

@testable import BackpocketKit

@Suite("HTMLToMarkdown")
struct HTMLToMarkdownTests {
    @Test func headingsAndParagraphs() {
        let markdown = HTMLToMarkdown.convert(
            "<h2>Title</h2><p>First paragraph.</p><p>Second.</p>"
        )
        #expect(markdown == "## Title\n\nFirst paragraph.\n\nSecond.")
    }

    @Test func inlineEmphasisAndLinks() {
        let markdown = HTMLToMarkdown.convert(
            "<p>Use <strong>bold</strong>, <em>italic</em> and <a href=\"https://example.com\">a link</a>.</p>"
        )
        #expect(markdown == "Use **bold**, *italic* and [a link](https://example.com).")
    }

    @Test func inlineCodeAndCodeBlock() {
        let markdown = HTMLToMarkdown.convert(
            "<p>Run <code>swift build</code>:</p><pre><code>let a = 1\nlet b = 2</code></pre>"
        )
        #expect(markdown?.contains("`swift build`") == true)
        #expect(markdown?.contains("```\nlet a = 1\nlet b = 2\n```") == true)
    }

    @Test func unorderedAndNestedLists() {
        let markdown = HTMLToMarkdown.convert(
            "<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>"
        )
        // The whole shape, not three substrings of it. "  - nested" is
        // contained in any wider indent, so the old assertions passed just as
        // happily with the nesting level multiplied — and they said nothing
        // at all about the blank line that would end the list early.
        #expect(markdown == "- one\n- two\n  - nested")
    }

    @Test func anestedListStaysAttachedToTheItemItBelongsTo() {
        // Paragraph spacing is for the outermost list only. A blank line in
        // front of a nested one closes the list in every Markdown reader, so
        // the sublist comes out as a separate list at the top level.
        let markdown = HTMLToMarkdown.convert(
            "<p>a</p><ul><li>two<ul><li>nested</li></ul></li></ul><p>b</p>"
        )
        #expect(markdown == "a\n\n- two\n  - nested\n\nb")
    }

    @Test func orderedListNumbering() {
        let markdown = HTMLToMarkdown.convert(
            "<ol><li>first</li><li>second</li><li>third</li></ol>"
        )
        #expect(markdown?.contains("1. first") == true)
        #expect(markdown?.contains("2. second") == true)
        #expect(markdown?.contains("3. third") == true)
    }

    @Test func blockquote() {
        let markdown = HTMLToMarkdown.convert("<blockquote><p>quoted line</p></blockquote>")
        #expect(markdown == "> quoted line")
    }

    @Test func scriptsAndStylesAreDropped() {
        let markdown = HTMLToMarkdown.convert(
            "<p>visible</p><script>alert(1)</script><style>p{color:red}</style>"
        )
        #expect(markdown == "visible")
    }

    @Test func entitiesAreDecoded() {
        let markdown = HTMLToMarkdown.convert("<p>a &amp; b &lt;tag&gt;</p>")
        #expect(markdown == "a & b <tag>")
    }

    @Test func imageBecomesMarkdownImage() {
        let markdown = HTMLToMarkdown.convert(
            "<p><img src=\"https://example.com/x.png\" alt=\"chart\"></p>"
        )
        #expect(markdown == "![chart](https://example.com/x.png)")
    }

    @Test func tableEmitsHeaderSeparator() {
        let markdown = HTMLToMarkdown.convert(
            "<table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>"
        )
        #expect(markdown == "| a | b |\n| --- | --- |\n| 1 | 2 |")
    }

    @Test func tableSectionWrappersAreTransparent() {
        let markdown = HTMLToMarkdown.convert(
            "<table><thead><tr><th>a</th><th>b</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>"
        )
        #expect(markdown == "| a | b |\n| --- | --- |\n| 1 | 2 |")
    }

    @Test func singleRowTableStillGetsSeparator() {
        let markdown = HTMLToMarkdown.convert("<table><tr><th>only</th></tr></table>")
        #expect(markdown == "| only |\n| --- |")
    }

    @Test func captionStaysOutsideTheTable() {
        let markdown = HTMLToMarkdown.convert(
            "<table><caption>Quarterly</caption><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>"
        )
        #expect(markdown == "Quarterly\n\n| a | b |\n| --- | --- |\n| 1 | 2 |")
    }

    @Test func lineBreakInCellIsFlattened() {
        let markdown = HTMLToMarkdown.convert(
            "<table><tr><th>one<br>two</th><th>b</th></tr><tr><td>c</td><td>d</td></tr></table>"
        )
        #expect(markdown == "| one two | b |\n| --- | --- |\n| c | d |")
    }

    @Test func blockContentInCellIsFlattened() {
        let markdown = HTMLToMarkdown.convert(
            "<table><tr><th>h1</th><th>h2</th></tr><tr><td><p>x</p></td><td><p>y</p></td></tr></table>"
        )
        #expect(markdown == "| h1 | h2 |\n| --- | --- |\n| x | y |")
    }

    @Test func layoutWhitespaceIsCollapsed() {
        let markdown = HTMLToMarkdown.convert(
            "<p>spread\n        across\n        lines</p>"
        )
        #expect(markdown == "spread across lines")
    }

    @Test func pathologicalNestingDoesNotOverflowTheStack() {
        // The HTML flavor is untrusted input; the walk must survive nesting
        // far past the render depth cap. Structure may flatten — crashing
        // is the only failure.
        let depth = 2_000
        let html =
            String(repeating: "<div>", count: depth) + "core"
            + String(repeating: "</div>", count: depth)

        let markdown = HTMLToMarkdown.convert(html)
        #expect(markdown == nil || markdown?.contains("core") == true)
    }

    @Test func aLongFlatDocumentIsNotMistakenForADeepOne() {
        // The pre-parse counts openers against closers. Counting a closer the
        // wrong way turns any ordinary page — which has thousands of tags and
        // nests a handful deep — into one the converter refuses outright, and
        // the user gets plain text back from a paste that used to be rich.
        let flat = String(repeating: "<p>line</p>", count: 300)
        let markdown = HTMLToMarkdown.convert(flat)
        #expect(markdown?.contains("line") == true)
    }

    @Test func aBareLessThanIsTextRatherThanAnUnterminatedTag() {
        // Prose copied out of a page carries comparisons in it. Reading the
        // trailing "<" as a tag that never closes would reject the whole
        // fragment, so the scan treats the rest as text and moves on.
        let markdown = HTMLToMarkdown.convert("<p>a</p>5 < 6")
        #expect(markdown?.contains("5 < 6") == true)
    }

    @Test func aTopLevelListIsSeparatedFromTheProseAroundIt() {
        // Only the outermost list takes paragraph spacing; a nested one
        // belongs to its parent item. Swap the two and either the list runs
        // into the sentence before it or every nested list opens a gap.
        let markdown = HTMLToMarkdown.convert(
            "<p>before</p><ul><li>one</li></ul><p>after</p>"
        )
        #expect(markdown == "before\n\n- one\n\nafter")
    }

    @Test func theWalkFlattensToTextExactlyAtItsDepthCap() throws {
        // The test above says the walk survives; this says where it stops.
        // Asked through `convert` the answer would depend on how many
        // wrappers tidy adds around the fragment, which a macOS update may
        // change — so the walk is handed its depth instead.
        func rendered(atDepth depth: Int) throws -> String {
            let element = try #require(
                try XMLDocument(xmlString: "<div><b>x</b></div>").rootElement())
            return HTMLToMarkdown.render(element, atDepth: depth)
        }

        // 200 is the cap, spelled out so that raising it — which the doc
        // comment ties to the main thread's 8 MB stack — has to be a
        // deliberate edit here too.
        #expect(try rendered(atDepth: 198).contains("**x**"))

        // One below the cap the div still renders, but its child sits on it:
        // the emphasis is lost and the text is not. Losing structure is the
        // whole trade, so a cap that quietly dropped content would be worse
        // than the crash it exists to prevent.
        let atTheEdge = try rendered(atDepth: 199)
        #expect(!atTheEdge.contains("**"))
        #expect(atTheEdge.contains("x"))

        // On the cap the element itself flattens, wrappers and all.
        #expect(try rendered(atDepth: 200) == "x")
    }

    @Test func emptyAndGarbageInputs() {
        #expect(HTMLToMarkdown.convert("") == nil)
        #expect(HTMLToMarkdown.convert("<script>x</script>") == nil)
    }
}

@Suite("TokenEstimate")
struct TokenEstimateTests {
    @Test func asciiAveragesFourCharsPerToken() {
        let text = String(repeating: "word", count: 100)
        #expect(TokenEstimate.roughCount(text) == 100)
    }

    @Test func cjkCountsRoughlyOneTokenPerCharacter() {
        #expect(TokenEstimate.roughCount("한국어테스트") == 6)
    }

    @Test func emptyIsZero() {
        #expect(TokenEstimate.roughCount("") == 0)
    }
}
