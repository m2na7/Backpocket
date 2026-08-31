import Foundation

/// How a clip's text should be rendered: prose or code.
enum ContentKind {
    case plain
    case code

    var isMonospaced: Bool { self == .code }
}

/// Classifies clip content and prepares it for display.
enum ContentFormatter {
    private static let codeMarkers = [
        "func ", "def ", "class ", "import ", "#include", "package ",
        "const ", "let ", "var ", "return ", "public ", "private ",
        "=>", "->", "&&", "||", "==", "!=", "://", "</", "/>",
    ]

    /// Heuristic code detection — no parsing, just surface signals.
    static func kind(of content: String) -> ContentKind {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plain }

        if isJSON(trimmed) { return .code }

        let lines = trimmed.components(separatedBy: "\n")

        // Multiple lines with indentation read as code.
        let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }
        if lines.count > 1, !indented.isEmpty { return .code }

        // Braces and semicolons recurring line after line read as code.
        if lines.count > 1 {
            let structural = lines.filter {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return line.hasSuffix("{") || line.hasSuffix("}")
                    || line.hasSuffix(";") || line.hasSuffix(",")
            }
            if structural.count >= 2 { return .code }
        }

        if codeMarkers.contains(where: trimmed.contains) { return .code }

        return .plain
    }

    /// Body for the detail view. JSON crammed onto one line is expanded,
    /// and indentation shifted wholesale is stripped.
    static func detail(of content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .newlines)

        if let pretty = prettyJSON(trimmed) { return pretty }
        return dedent(trimmed)
    }

    // MARK: Internals

    private static func isJSON(_ text: String) -> Bool {
        guard text.hasPrefix("{") || text.hasPrefix("["), let data = text.data(using: .utf8) else {
            return false
        }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// JSON already laid out across lines is left untouched — re-serializing
    /// would scramble the key order.
    private static func prettyJSON(_ text: String) -> String? {
        guard
            !text.contains("\n"),
            isJSON(text),
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .withoutEscapingSlashes]
            )
        else { return nil }

        return String(data: pretty, encoding: .utf8)
    }

    /// Copied code carries the indentation of wherever it came from.
    /// Strip the common prefix.
    private static func dedent(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let indents =
            lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }

        guard let common = indents.min(), common > 0 else { return text }

        return
            lines
            .map { String($0.dropFirst(min(common, $0.count))) }
            .joined(separator: "\n")
    }
}
