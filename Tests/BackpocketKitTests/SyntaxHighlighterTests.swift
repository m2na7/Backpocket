import SwiftUI
import Testing

@testable import BackpocketKit

@Suite("CodeLanguage.detect")
struct CodeLanguageDetectTests {
    @Test("Swift markers: func and @State")
    func detectsSwift() {
        #expect(CodeLanguage.detect("func greet() -> String { \"hi\" }") == .swift)
        #expect(CodeLanguage.detect("@State private var count = 0") == .swift)
    }

    @Test("TypeScript interface with typed fields")
    func detectsTypeScript() {
        let code = """
            interface User {
                name: string;
                age: number;
            }
            """
        #expect(CodeLanguage.detect(code) == .typescript)
    }

    @Test("JavaScript arrow const")
    func detectsJavaScript() {
        #expect(CodeLanguage.detect("const add = (a, b) => a + b;") == .javascript)
    }

    @Test("JSON, single-line and multi-line")
    func detectsJSON() {
        #expect(CodeLanguage.detect(#"{"name": "backpocket", "count": 3}"#) == .json)
        let multiline = """
            {
                "items": [1, 2, 3],
                "nested": { "ok": true }
            }
            """
        #expect(CodeLanguage.detect(multiline) == .json)
    }

    @Test("Markdown headings and lists")
    func detectsMarkdown() {
        let doc = """
            # Title

            - first item
            - second item
            """
        #expect(CodeLanguage.detect(doc) == .markdown)
    }

    @Test("Two marked lines are enough for markdown, one is not")
    func twoMarkedLinesAreTheThreshold() {
        // Unfenced markdown is recognized by counting marked lines, and two
        // is the count. Pinned from both sides because either mistake is
        // visible: raise it and a short note stops being formatted, lower it
        // and a bullet in the middle of prose monospaces the whole clip.
        #expect(CodeLanguage.detect("# Title\n- first item") == .markdown)
        #expect(CodeLanguage.detect("# Title\nan ordinary sentence") == .generic)
    }

    @Test("Code fence wins over inner-language markers")
    func fenceBeatsInnerLanguage() {
        // Regression: fenced JS used to flip the whole document to .javascript,
        // so markdown containing examples lost its formatting.
        let doc = """
            Some notes about the helper:

            ```
            const x = () => 1;
            console.log(x);
            ```
            """
        #expect(CodeLanguage.detect(doc) == .markdown)
    }

    @Test("Shebang and shell commands")
    func detectsShell() {
        #expect(CodeLanguage.detect("#!/bin/bash\necho hello") == .shell)
        #expect(CodeLanguage.detect("git status\nnpm install") == .shell)
    }

    @Test("Plain Korean prose stays generic")
    func detectsGeneric() {
        let prose = "오늘 회의에서 논의한 내용을 정리했다. 내일까지 자료를 공유하기로 했다."
        #expect(CodeLanguage.detect(prose) == .generic)
    }
}

@Suite("SyntaxHighlighter.highlight")
struct SyntaxHighlighterTests {
    private let swiftSnippet = """
        // greet the user
        func greet(times: Int) -> String {
            let message = "hello"
            return message + String(42)
        }
        """

    @Test("Flattened output equals input exactly")
    func roundTripPreservesContent() {
        // The highlighter rebuilds the string token by token; any drift here
        // corrupts what the user copies back out, so equality must be exact.
        let inputs = [
            swiftSnippet,
            "let path = \"C:\\\\Users\\\\me\"\nlet open = \"unterminated",
            "# Heading\n\n- item\n- item\n\ntrailing text\n",
        ]
        for input in inputs {
            let language = CodeLanguage.detect(input)
            let highlighted = SyntaxHighlighter.highlight(input, language: language)
            #expect(String(highlighted.characters) == input)
        }
    }

    @Test("Swift snippet produces colored runs per token kind")
    func swiftSnippetHasColoredRuns() {
        let highlighted = SyntaxHighlighter.highlight(swiftSnippet, language: .swift)
        let coloredRuns = highlighted.runs.filter { $0.foregroundColor != nil }
        #expect(coloredRuns.count >= 5)
    }

    @Test("Uniformly styled text collapses to one run")
    func uniformTextIsOneRun() {
        // Layout is charged per run, not per character: at the 6,000-character
        // cap, emitting one run per token cost ~240 ms against ~43 ms for the
        // same text unstyled. Anything that agrees on color must therefore
        // arrive as a single run however long it runs on.
        let comments = String(repeating: "// note\n", count: 400)
        #expect(SyntaxHighlighter.highlight(comments, language: .swift).runs.count == 1)

        let prose = String(repeating: "plain markdown line\n", count: 200)
        #expect(SyntaxHighlighter.highlight(prose, language: .markdown).runs.count == 1)
    }

    @Test("Whitespace joins its neighbor instead of forming a run")
    func whitespaceDoesNotSplitRuns() {
        // Whitespace draws nothing, so a run of its own buys no color the
        // reader can see and lands a boundary between nearly every pair of
        // tokens — which is most of the layout cost the run count above pins.
        let highlighted = SyntaxHighlighter.highlight(swiftSnippet, language: .swift)
        let blankRuns = highlighted.runs.filter {
            highlighted[$0.range].characters.allSatisfy(\.isWhitespace)
        }
        #expect(blankRuns.isEmpty)
    }

    @Test("A marker that ends the text is still a comment")
    func markerFlushAgainstTheEndIsAcomment() throws {
        // The scanner compares a marker against the characters ahead of it,
        // and the last position in the text is the one where that lookahead
        // has exactly no room to spare. A snippet trailing off after `//` is
        // ordinary half-written code, and it used to be the one place the
        // marker read as two stray punctuation marks instead.
        let highlighted = SyntaxHighlighter.highlight("let x = 1 //", language: .swift)
        let last = try #require(highlighted.runs.last)

        #expect(String(highlighted[last.range].characters).hasSuffix("//"))
        #expect(last.foregroundColor == CodeTheme.default.comment)
    }

    /// The text of the first run painted in `color`, or nil when none is.
    ///
    /// Trailing whitespace is dropped because the run that follows a token
    /// absorbs it — see `whitespaceDoesNotSplitRuns`, which is the reason it
    /// does. Where a token ends is the question here; where the spaces after
    /// it were filed is a different one, already pinned elsewhere.
    private func firstRun(_ color: Color, in text: AttributedString) -> String? {
        text.runs.first { $0.foregroundColor == color }
            .map { String(text[$0.range].characters) }
            .map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }
    }

    @Test("A string literal ends at its own quote, not at an escaped one")
    func stringRunsSpanTheWholeLiteral() {
        // Two ways to end a literal early, and both leave the rest of the
        // line painted as code: stop at the escaped quote, or stop at the
        // first character that is not the quote at all. Either one shows up
        // as a string run that is shorter than the literal.
        let highlighted = SyntaxHighlighter.highlight(
            #"let s = "a\"b" + tail"#, language: .swift)
        #expect(firstRun(CodeTheme.default.string, in: highlighted) == #""a\"b""#)
    }

    @Test("A block comment run includes its closing marker")
    func blockCommentRunsIncludeTheirTerminator() {
        // The scanner steps past `*/` before closing the run. Stepping the
        // wrong way leaves the two marker characters outside the comment,
        // coloured as whatever the language makes of a stray slash.
        let highlighted = SyntaxHighlighter.highlight("/* note */ let x = 1", language: .swift)
        #expect(firstRun(CodeTheme.default.comment, in: highlighted) == "/* note */")
    }

    @Test("Only the C-like languages have block comments")
    func blockCommentsBelongToTheCLikeLanguagesOnly() {
        // Asked of the highlighter rather than of the flag: `/* */` is a
        // comment in Swift and three tokens of punctuation in a shell script,
        // and a language list that drifts shows up here as either a comment
        // that stops being one or prose that starts being one.
        let source = "/* note */ x"
        let swift = SyntaxHighlighter.highlight(source, language: .swift)
        let shell = SyntaxHighlighter.highlight(source, language: .shell)

        #expect(firstRun(CodeTheme.default.comment, in: swift) == "/* note */")
        #expect(firstRun(CodeTheme.default.comment, in: shell) == nil)
    }

    @Test("Capitalization is what marks a word as a type")
    func onlyCapitalizedWordsAreColoredAsTypes() {
        // The one signal this highlighter has for a type, with no parser
        // behind it. Inverted, every local variable in the snippet takes the
        // type colour and the distinction stops meaning anything.
        let highlighted = SyntaxHighlighter.highlight("let value = String(1)", language: .swift)
        #expect(firstRun(CodeTheme.default.type, in: highlighted) == "String")
    }

    @Test("Oversized input returns a single plain run quickly")
    func oversizedInputShortCircuits() {
        // 6,000 characters is the cap, and both sides of it are pinned: an
        // assertion against a number far past the cap passes no matter where
        // the cap actually sits.
        let atLimit = String(repeating: "let x = 1\n", count: 600)
        #expect(atLimit.count == 6_000)
        #expect(SyntaxHighlighter.highlight(atLimit, language: .swift).runs.count > 1)

        let overLimit = atLimit + " "
        #expect(overLimit.count == 6_001)
        let plain = SyntaxHighlighter.highlight(overLimit, language: .swift)
        #expect(plain.runs.count == 1)
        #expect(String(plain.characters) == overLimit)
    }
}
