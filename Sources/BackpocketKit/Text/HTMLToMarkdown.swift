import Foundation

/// Converts the HTML flavor a browser puts on the pasteboard into clean
/// Markdown. Foundation's HTML-tidy parser normalizes the messy fragment
/// into a proper tree first, so the walk itself stays simple — and the
/// whole thing needs no dependencies.
enum HTMLToMarkdown {
    static func convert(_ html: String) -> String? {
        // Checked BEFORE parsing: tidy itself recurses per element, so a
        // render-side cap alone cannot protect against a parser that blows
        // the stack first (reproduced in tests at ~2000 nested tags).
        guard !nestsTooDeep(html) else { return nil }

        guard
            let data = html.data(using: .utf8),
            let document = try? XMLDocument(data: data, options: [.documentTidyHTML]),
            let root = document.rootElement()
        else { return nil }

        let body = firstElement(named: "body", under: root) ?? root
        let rendered = render(body, context: Context())
            // Trailing-only: leading spaces are list indents and code blocks.
            .replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return rendered.isEmpty ? nil : rendered
    }

    // MARK: Tree walk

    private struct Context {
        var listDepth = 0
        var ordered = false
        var itemIndex = 0
        var insidePre = false
        var depth = 0
    }

    /// The walk recurses per element and the HTML flavor is untrusted input
    /// up to 300k chars — room for enough nested tags to blow the stack.
    /// Everything else in the pipeline is bounded; this bounds the last gap.
    ///
    /// **This number assumes the main thread's 8 MB stack.** Measured off it,
    /// on a 512 KB cooperative-pool thread, the walk takes down the whole
    /// process with a SIGBUS at roughly 100 nested tags — a crash, not a
    /// catchable error, and a depth this cap admits. The only caller is
    /// main-actor (`AppDelegate.pasteMarkdown`), which is what keeps it safe,
    /// so that is a constraint rather than an accident: moving HTML
    /// conversion off the main thread means lowering this first.
    private static let maxDepth = 200

    /// Elements that never take a closing tag; counting them as openers
    /// would reject any ordinary page with a few hundred <br> or <img>.
    private static let voidTags: Set<Substring> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// A linear pre-parse depth estimate. It overcounts for malformed
    /// nesting — which only makes pathological input fail sooner — and never
    /// undercounts a well-formed document.
    private static func nestsTooDeep(_ html: String) -> Bool {
        var depth = 0
        var index = html.startIndex

        while let open = html[index...].firstIndex(of: "<") {
            guard let close = html[open...].firstIndex(of: ">") else { return false }
            let inner = html[html.index(after: open)..<close]
            index = html.index(after: close)

            if inner.hasPrefix("/") {
                depth = max(0, depth - 1)
                continue
            }
            guard inner.first?.isLetter == true else { continue }
            if inner.hasSuffix("/") { continue }

            let name = inner.prefix { $0.isLetter || $0.isNumber }
            if voidTags.contains(Substring(name.lowercased())) { continue }

            depth += 1
            if depth > maxDepth { return true }
        }
        return false
    }

    private static let dropped: Set<String> = [
        "script", "style", "head", "title", "meta", "link", "iframe", "noscript", "svg",
    ]

    #if DEBUG
    /// Renders one node as if the walk had already descended `depth` levels.
    ///
    /// The cap is otherwise only reachable through a document nested deep
    /// enough for tidy to have added its own wrappers, which makes the input
    /// that lands on the boundary a function of how many of those a given
    /// macOS adds — not something this project should be pinning. Handing the
    /// walk its depth asks the same question without the guesswork.
    static func render(_ node: XMLNode, atDepth depth: Int) -> String {
        render(node, context: Context(depth: depth))
    }
    #endif

    private static func render(_ node: XMLNode, context: Context) -> String {
        if node.kind == .text {
            let text = node.stringValue ?? ""
            if context.insidePre { return text }
            // Tidy leaves layout newlines in text nodes; they are not content.
            return text.replacingOccurrences(
                of: "\\s+", with: " ", options: .regularExpression
            )
        }

        guard let element = node as? XMLElement else { return "" }
        let name = element.name?.lowercased() ?? ""
        if dropped.contains(name) { return "" }

        // Past the cap the subtree flattens to its text — losing structure
        // beats crashing on pathological nesting.
        if context.depth >= maxDepth {
            return element.stringValue ?? ""
        }

        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(name.dropFirst())) ?? 1
            let marks = String(repeating: "#", count: level)
            return "\n\n\(marks) \(children(element, context: context))\n\n"

        case "p", "div", "section", "article", "main", "header", "footer", "figure":
            return "\n\n\(children(element, context: context))\n\n"

        case "br":
            return "\n"

        case "hr":
            return "\n\n---\n\n"

        case "strong", "b":
            return wrap(children(element, context: context), in: "**")

        case "em", "i":
            return wrap(children(element, context: context), in: "*")

        case "del", "s", "strike":
            return wrap(children(element, context: context), in: "~~")

        case "code" where !context.insidePre:
            return "`\(element.stringValue ?? "")`"

        case "pre":
            var inner = context
            inner.insidePre = true
            let code = children(element, context: inner)
                .trimmingCharacters(in: .newlines)
            return "\n\n```\n\(code)\n```\n\n"

        case "a":
            let text = children(element, context: context)
                .trimmingCharacters(in: .whitespaces)
            let href = element.attribute(forName: "href")?.stringValue ?? ""
            if href.isEmpty || text.isEmpty { return text }
            return "[\(text)](\(href))"

        case "img":
            let alt = element.attribute(forName: "alt")?.stringValue ?? ""
            let src = element.attribute(forName: "src")?.stringValue ?? ""
            return src.isEmpty ? "" : "![\(alt)](\(src))"

        case "ul", "ol":
            var inner = context
            inner.listDepth += 1
            inner.ordered = name == "ol"
            inner.itemIndex = 0
            var out = "\n"
            for child in element.children ?? [] {
                guard (child as? XMLElement)?.name?.lowercased() == "li" else { continue }
                inner.itemIndex += 1
                out += listItem(child as! XMLElement, context: inner)
            }
            // A nested list belongs to its parent item; only the outermost
            // list gets paragraph spacing.
            return context.listDepth == 0 ? "\n" + out + "\n" : out

        case "blockquote":
            let inner = children(element, context: context)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let quoted =
                inner
                .components(separatedBy: "\n")
                .map { "> " + $0 }
                .joined(separator: "\n")
            return "\n\n\(quoted)\n\n"

        case "tr":
            let cells = (element.children ?? [])
                .compactMap { $0 as? XMLElement }
                .filter { ["td", "th"].contains($0.name?.lowercased() ?? "") }
                .map {
                    // GFM cells cannot hold a literal newline, so <br> and
                    // block children inside a cell flatten to spaces — the
                    // row must stay on one line for the "table" case to
                    // reassemble the grid.
                    children($0, context: context)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(
                            of: "\\s*\n\\s*", with: " ", options: .regularExpression
                        )
                }
            return cells.isEmpty ? "" : "| " + cells.joined(separator: " | ") + " |\n"

        case "caption":
            // Rendered inline, caption text would fuse onto the header row;
            // a block of its own lets the "table" case lift it out.
            return "\n\n\(children(element, context: context))\n\n"

        case "table":
            // Rows arrive one per line from the "tr" case. GFM only
            // recognizes a table when a delimiter row follows the header,
            // so one is synthesized from the first row's column count.
            // Caption or stray prose would corrupt the grid, so it moves
            // above the table instead.
            let lines = children(element, context: context)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let rows = lines.filter { $0.hasPrefix("|") }
            let prose = lines.filter { !$0.hasPrefix("|") }
            guard let header = rows.first else {
                return prose.isEmpty ? "" : "\n\n" + prose.joined(separator: "\n\n") + "\n\n"
            }
            let separator =
                "|"
                + String(
                    repeating: " --- |", count: header.split(separator: "|").count
                )
            let table = ([header, separator] + rows.dropFirst()).joined(separator: "\n")
            return "\n\n" + (prose + [table]).joined(separator: "\n\n") + "\n\n"

        default:
            return children(element, context: context)
        }
    }

    private static func listItem(_ element: XMLElement, context: Context) -> String {
        let indent = String(repeating: "  ", count: context.listDepth - 1)
        let marker = context.ordered ? "\(context.itemIndex). " : "- "
        let body = children(element, context: context)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return indent + marker + body + "\n"
    }

    private static func children(_ element: XMLElement, context: Context) -> String {
        var context = context
        context.depth += 1
        return (element.children ?? [])
            .map { render($0, context: context) }
            .joined()
    }

    /// Emphasis markers touching whitespace break Markdown parsing,
    /// so the padding moves outside the markers.
    private static func wrap(_ text: String, in marker: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let leading = text.hasPrefix(" ") ? " " : ""
        let trailing = text.hasSuffix(" ") ? " " : ""
        return leading + marker + trimmed + marker + trailing
    }

    /// Iterative on purpose — the render walk is depth-capped, and this must
    /// not be the one remaining unbounded recursion over untrusted markup.
    private static func firstElement(named name: String, under node: XMLElement) -> XMLElement? {
        var queue: [XMLElement] = [node]
        while !queue.isEmpty {
            let element = queue.removeFirst()
            if element.name?.lowercased() == name { return element }
            queue.append(contentsOf: (element.children ?? []).compactMap { $0 as? XMLElement })
        }
        return nil
    }
}

/// A rough LLM token estimate — close enough to judge "will this fit in a
/// prompt" without shipping a tokenizer. BPE averages ~4 ASCII characters
/// per token, while CJK runs closer to one token per character.
enum TokenEstimate {
    static func roughCount(_ text: String) -> Int {
        var ascii = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { other += 1 }
        }
        return max(ascii / 4 + other, text.isEmpty ? 0 : 1)
    }
}
