import AppKit
import SwiftUI

// MARK: Languages

/// The handful of languages worth telling apart in a clipboard preview.
enum CodeLanguage: String {
    case swift = "Swift"
    case typescript = "TypeScript"
    case javascript = "JavaScript"
    case json = "JSON"
    case markdown = "Markdown"
    case shell = "Shell"
    case generic = "Text"

    var keywords: Set<String> {
        switch self {
        case .swift:
            [
                "func", "let", "var", "if", "else", "guard", "return", "struct", "class",
                "enum", "protocol", "extension", "import", "private", "public", "internal",
                "static", "self", "init", "for", "in", "while", "switch", "case", "default",
                "try", "catch", "throws", "async", "await", "nil", "true", "false", "some",
                "where", "as", "is", "weak", "final", "override", "lazy", "defer",
            ]
        case .typescript, .javascript:
            [
                "const", "let", "var", "function", "return", "if", "else", "for", "while",
                "import", "export", "from", "default", "class", "extends", "new", "this",
                "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof",
                "null", "undefined", "true", "false", "interface", "type", "enum", "implements",
                "public", "private", "readonly", "as", "switch", "case", "break", "continue",
            ]
        case .json:
            ["true", "false", "null"]
        case .shell:
            [
                "cd", "echo", "export", "if", "then", "fi", "for", "do", "done", "sudo",
                "npm", "pnpm", "yarn", "git", "swift", "brew", "rm", "cp", "mv", "mkdir",
            ]
        case .markdown, .generic:
            []
        }
    }

    var lineComment: String? {
        switch self {
        case .swift, .typescript, .javascript: "//"
        case .shell: "#"
        case .json, .markdown, .generic: nil
        }
    }

    var hasBlockComment: Bool {
        self == .swift || self == .typescript || self == .javascript
    }

    /// Guesses the language from surface markers alone.
    static func detect(_ text: String) -> CodeLanguage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .generic }

        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
            let data = trimmed.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return .json
        }

        if trimmed.hasPrefix("#!") { return .shell }

        // Markdown is a format that embeds code, so check for fences first.
        // Judging by the inner code would classify MDX as that code's language.
        if trimmed.contains("```") { return .markdown }

        if contains(trimmed, ["func ", "guard ", "-> ", "import Foundation", "@State", "@Model"]) {
            return .swift
        }
        if contains(
            trimmed, ["interface ", ": string", ": number", "readonly ", "<T>", "as const"])
        {
            return .typescript
        }
        if contains(trimmed, ["const ", "function ", "=>", "export ", "require(", "console."]) {
            // Without TS-specific markers this stays JavaScript — the coloring
            // comes out the same either way.
            return .javascript
        }
        if isMarkdown(trimmed) { return .markdown }
        if contains(trimmed, ["npm ", "pnpm ", "git ", "brew ", "sudo "]) { return .shell }

        return .generic
    }

    private static func contains(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func isMarkdown(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        let marked = lines.filter { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return l.hasPrefix("#") || l.hasPrefix("- ") || l.hasPrefix("* ")
                || l.hasPrefix("```") || l.hasPrefix("> ")
        }
        return marked.count >= 2 || text.contains("```")
    }
}

// MARK: Theme

/// Colors live in this one place only. A future theme picker in settings
/// only needs to swap this struct.
struct CodeTheme {
    var plain: Color
    var keyword: Color
    var string: Color
    var number: Color
    var comment: Color
    var type: Color
    var punctuation: Color

    /// A palette developers already know. Light/dark values come in pairs so
    /// it follows the system appearance.
    static let `default` = CodeTheme(
        plain: .primary,
        keyword: dynamic(light: 0xCF_22_2E, dark: 0xFF_7B_72),
        string: dynamic(light: 0x0A_30_69, dark: 0xA5_D6_FF),
        number: dynamic(light: 0x05_50_AE, dark: 0x79_C0_FF),
        comment: dynamic(light: 0x6E_77_81, dark: 0x8B_94_9E),
        type: dynamic(light: 0x82_50_DF, dark: 0xD2_A8_FF),
        punctuation: .secondary
    )

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(rgb: isDark ? dark : light)
            }
        )
    }
}

extension NSColor {
    fileprivate convenience init(rgb: Int) {
        self.init(
            srgbRed: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: Highlighting

/// Dependency-free token colorer for the detail view.
enum SyntaxHighlighter {
    /// Scanning a huge paste would delay the panel from appearing.
    /// Only the head gets colored; the rest is left plain.
    private static let limit = 6_000

    static func highlight(
        _ text: String,
        language: CodeLanguage,
        theme: CodeTheme = .default
    ) -> AttributedString {
        guard text.count <= limit else {
            var plain = AttributedString(text)
            plain.foregroundColor = theme.plain
            return plain
        }

        if language == .markdown {
            return markdown(text, theme: theme)
        }
        return scan(text, language: language, theme: theme)
    }

    // MARK: Runs

    /// Run count — not character count — is what text layout charges for: at
    /// the 6,000-character cap, one run per four characters costs about five
    /// times the layout of one run for the whole string. Pieces pile up here
    /// and only become a run when the attributes actually change.
    private struct Runs {
        private var output = AttributedString()
        private var pending = ""
        private var color: Color?
        private var emphasis: InlinePresentationIntent?

        mutating func append(
            _ piece: String,
            color: Color?,
            emphasis: InlinePresentationIntent? = nil
        ) {
            if color != self.color || emphasis != self.emphasis {
                flush()
                self.color = color
                self.emphasis = emphasis
            }
            pending += piece
        }

        /// Whitespace draws no ink, so which color it carries is unobservable.
        /// Letting it join whatever run precedes it drops the boundary that
        /// otherwise sits between nearly every pair of tokens.
        mutating func appendBlank(_ piece: String, ifLeading fallback: Color) {
            guard !pending.isEmpty else { return append(piece, color: fallback) }
            pending += piece
        }

        mutating func finish() -> AttributedString {
            flush()
            return output
        }

        private mutating func flush() {
            guard !pending.isEmpty else { return }
            var run = AttributedString(pending)
            run.foregroundColor = color
            run.inlinePresentationIntent = emphasis
            output += run
            pending = ""
        }
    }

    // MARK: General languages — a single pass that cuts tokens as it goes

    private static func scan(
        _ text: String,
        language: CodeLanguage,
        theme: CodeTheme
    ) -> AttributedString {
        var output = Runs()
        let characters = Array(text)
        let keywords = language.keywords
        var index = 0

        func append(_ piece: String, _ color: Color) {
            output.append(piece, color: color)
        }

        while index < characters.count {
            let character = characters[index]

            if let marker = language.lineComment,
                matches(characters, at: index, prefix: marker)
            {
                let start = index
                while index < characters.count, characters[index] != "\n" { index += 1 }
                append(String(characters[start..<index]), theme.comment)
                continue
            }

            if language.hasBlockComment, matches(characters, at: index, prefix: "/*") {
                let start = index
                index += 2
                while index < characters.count, !matches(characters, at: index, prefix: "*/") {
                    index += 1
                }
                index = min(index + 2, characters.count)
                append(String(characters[start..<index]), theme.comment)
                continue
            }

            if character == "\"" || character == "'" || character == "`" {
                let start = index
                index += 1
                while index < characters.count {
                    if characters[index] == "\\" {
                        index += 2
                        continue
                    }
                    if characters[index] == character {
                        index += 1
                        break
                    }
                    index += 1
                }
                append(String(characters[start..<min(index, characters.count)]), theme.string)
                continue
            }

            if character.isNumber {
                let start = index
                while index < characters.count,
                    characters[index].isNumber || characters[index] == "."
                {
                    index += 1
                }
                append(String(characters[start..<index]), theme.number)
                continue
            }

            if character.isLetter || character == "_" || character == "@" || character == "#" {
                let start = index
                while index < characters.count,
                    characters[index].isLetter || characters[index].isNumber
                        || characters[index] == "_" || characters[index] == "@"
                        || characters[index] == "#"
                {
                    index += 1
                }
                let word = String(characters[start..<index])

                if keywords.contains(word) || word.hasPrefix("@") || word.hasPrefix("#") {
                    append(word, theme.keyword)
                } else if word.first?.isUppercase == true {
                    append(word, theme.type)
                } else {
                    append(word, theme.plain)
                }
                continue
            }

            if character.isWhitespace {
                let start = index
                while index < characters.count, characters[index].isWhitespace { index += 1 }
                output.appendBlank(String(characters[start..<index]), ifLeading: theme.plain)
                continue
            }

            append(String(character), theme.punctuation)
            index += 1
        }

        return output.finish()
    }

    private static func matches(_ characters: [Character], at index: Int, prefix: String) -> Bool {
        let needle = Array(prefix)
        guard index + needle.count <= characters.count else { return false }
        return Array(characters[index..<(index + needle.count)]) == needle
    }

    // MARK: Markdown — judged line by line

    private static func markdown(_ text: String, theme: CodeTheme) -> AttributedString {
        var output = Runs()

        for (offset, line) in text.components(separatedBy: "\n").enumerated() {
            if offset > 0 {
                output.appendBlank("\n", ifLeading: theme.plain)
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                output.append(line, color: theme.keyword, emphasis: .stronglyEmphasized)
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("> ") {
                output.append(line, color: theme.comment)
            } else {
                output.append(line, color: theme.plain)
            }
        }

        return output.finish()
    }
}
