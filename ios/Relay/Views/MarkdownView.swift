import SwiftUI
import UIKit

// MARK: - Block model

struct MDListItem: Hashable {
    enum Marker: Hashable {
        case bullet
        case number(String)
        case task(Bool)
    }

    var level: Int
    var marker: Marker
    var text: String
}

enum MDBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MDListItem])
    case quote(String)
    case code(language: String, code: String, closed: Bool)
    case table([[String]])
    case rule
}

struct MDNode: Identifiable, Hashable {
    let id: Int
    let block: MDBlock
}

// MARK: - Lightweight Markdown block parser (inline styling via AttributedString)

enum MarkdownParser {
    static func parse(_ raw: String) -> [MDNode] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        closed = true
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language, code: codeLines.joined(separator: "\n"), closed: closed))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            if let heading = headingInfo(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var content = String(t.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoteLines.append(content)
                    i += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if listItem(line) != nil {
                flushParagraph()
                var items: [MDListItem] = []
                while i < lines.count {
                    let current = lines[i]
                    if let item = listItem(current) {
                        items.append(item)
                        i += 1
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty,
                              current.hasPrefix("  ") || current.hasPrefix("\t"),
                              !items.isEmpty {
                        // continuation line of the previous item
                        items[items.count - 1].text += "\n" + current.trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items))
                continue
            }

            if trimmed.hasPrefix("|") && trimmed.dropFirst().contains("|") {
                flushParagraph()
                var rows: [[String]] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    let cells = tableCells(t)
                    if !isTableSeparator(cells) { rows.append(cells) }
                    i += 1
                }
                blocks.append(.table(rows))
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()

        return blocks.enumerated().map { MDNode(id: $0.offset, block: $0.element) }
    }

    private static func headingInfo(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> MDListItem? {
        var indent = 0
        for ch in line {
            if ch == " " { indent += 1 } else if ch == "\t" { indent += 4 } else { break }
        }
        let body = line.trimmingCharacters(in: .whitespaces)
        let level = min(indent / 2, 4)

        for prefix in ["- ", "* ", "+ "] where body.hasPrefix(prefix) {
            var rest = String(body.dropFirst(2))
            if rest.hasPrefix("[ ] ") {
                rest.removeFirst(4)
                return MDListItem(level: level, marker: .task(false), text: rest)
            }
            if rest.lowercased().hasPrefix("[x] ") {
                rest.removeFirst(4)
                return MDListItem(level: level, marker: .task(true), text: rest)
            }
            return MDListItem(level: level, marker: .bullet, text: rest)
        }

        var digits = ""
        for ch in body {
            if ch.isASCII && ch.isNumber { digits.append(ch) } else { break }
        }
        if !digits.isEmpty, digits.count <= 3 {
            let after = body.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return MDListItem(level: level, marker: .number(digits), text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            let c = cell.replacingOccurrences(of: ":", with: "")
            return !c.isEmpty && c.allSatisfy { $0 == "-" }
        }
    }

    /// Inline Markdown (bold, italic, `code`, links, strikethrough) → AttributedString.
    static func inline(_ text: String, tint: Color) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let codeFont = Font.system(size: 14.5, weight: .medium, design: .monospaced)
        let codeBackground: Color = Palette.fieldFill
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].font = codeFont
                attributed[run.range].foregroundColor = tint
                attributed[run.range].backgroundColor = codeBackground
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = tint
            }
        }
        return attributed
    }
}

// MARK: - Markdown view

struct MarkdownView: View {
    let text: String
    let style: AgentStyle
    var isStreaming: Bool = false

    var body: some View {
        let nodes = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(nodes) { node in
                blockView(node.block, isLast: node.id == nodes.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock, isLast: Bool) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(MarkdownParser.inline(content, tint: style.tint))
                .font(headingFont(level))
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, level <= 2 ? 6 : 2)
                .textSelection(.enabled)

        case .paragraph(let content):
            Text(MarkdownParser.inline(content, tint: style.tint))
                .font(RelayFont.body)
                .lineSpacing(5)
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .list(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        marker(item.marker)
                        Text(MarkdownParser.inline(item.text, tint: style.tint))
                            .font(RelayFont.body)
                            .lineSpacing(4)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.level) * 18)
                }
            }
            .textSelection(.enabled)

        case .quote(let content):
            HStack(alignment: .top, spacing: 12) {
                Capsule()
                    .fill(style.tint.opacity(0.55))
                    .frame(width: 3)
                Text(MarkdownParser.inline(content, tint: style.tint))
                    .font(.system(size: 15.5))
                    .italic()
                    .lineSpacing(4)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

        case .code(let language, let code, let closed):
            CodeBlockCard(language: language, code: code, isStreaming: isStreaming && isLast && !closed)

        case .table(let rows):
            TableBlock(rows: rows, tint: style.tint)

        case .rule:
            Rectangle()
                .fill(Palette.hairlineStrong)
                .frame(height: 0.6)
                .padding(.vertical, 6)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return RelayFont.display(23, weight: .bold)
        case 2: return RelayFont.display(20, weight: .semibold)
        case 3: return .system(size: 17, weight: .semibold)
        default: return .system(size: 15.5, weight: .semibold)
        }
    }

    @ViewBuilder
    private func marker(_ marker: MDListItem.Marker) -> some View {
        switch marker {
        case .bullet:
            Text("•")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(style.tint)
                .frame(minWidth: 12)
        case .number(let n):
            Text("\(n).")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(style.tint)
                .frame(minWidth: 18, alignment: .trailing)
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(done ? style.tint : Palette.textTertiary)
        }
    }
}

// MARK: - Table

struct TableBlock: View {
    let rows: [[String]]
    let tint: Color

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { col in
                            Text(MarkdownParser.inline(col < row.count ? row[col] : "", tint: tint))
                                .font(.system(size: 14, weight: index == 0 ? .semibold : .regular))
                                .foregroundStyle(index == 0 ? Palette.textPrimary : Palette.textSecondary)
                                .fixedSize()
                        }
                    }
                    if index == 0 {
                        Rectangle()
                            .fill(Palette.hairlineStrong)
                            .frame(height: 0.6)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(14)
        }
        .cardSurface(radius: 16)
    }
}

// MARK: - Code block card

struct CodeBlockCard: View {
    let language: String
    let code: String
    var isStreaming: Bool = false

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(RelayFont.mono(11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                }
                Spacer()
                Button(action: copy) {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                        Text(copied ? "已复制" : "复制")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(copied ? Color(hex: 0x5FD8A0) : Color.white.opacity(0.68))
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制代码")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Palette.codeHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(code, language: language))
                    .font(RelayFont.mono(13.5))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(14)
            }
        }
        .background(Palette.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.codeBorder, lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
    }

    private func copy() {
        UIPasteboard.general.string = code
        Haptics.success()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}

// MARK: - Syntax highlighting (linear, regex-based, dependency-free)

enum SyntaxHighlighter {
    private enum Token: UInt8 {
        case plain = 0
        case keyword
        case string
        case number
        case comment
        case type
    }

    private static let keywordList = [
        "func", "let", "var", "const", "if", "else", "for", "while", "return", "import", "from", "class",
        "struct", "enum", "def", "fn", "pub", "async", "await", "try", "catch", "throw", "throws", "new",
        "true", "false", "nil", "null", "None", "True", "False", "self", "this", "export", "default",
        "interface", "type", "public", "private", "protected", "static", "extends", "implements", "in",
        "of", "guard", "switch", "case", "break", "continue", "do", "package", "use", "mut", "impl",
        "match", "lambda", "yield", "with", "as", "is", "not", "and", "or", "elif", "except", "finally",
        "raise", "pass", "function", "echo", "then", "fi", "done", "esac", "select", "where", "go",
        "defer", "chan", "map", "struct", "protocol", "extension", "init", "override", "final", "some", "any",
    ]

    private static let keywordRegex = try? NSRegularExpression(
        pattern: "\\b(" + keywordList.joined(separator: "|") + ")\\b"
    )
    private static let numberRegex = try? NSRegularExpression(pattern: "\\b(0x[0-9a-fA-F]+|\\d+(\\.\\d+)?)\\b")
    private static let typeRegex = try? NSRegularExpression(pattern: "\\b[A-Z][A-Za-z0-9_]+\\b")
    private static let stringRegex = try? NSRegularExpression(
        pattern: "\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*'|`(?:[^`\\\\]|\\\\.)*`"
    )
    private static let slashCommentRegex = try? NSRegularExpression(
        pattern: "//[^\\n]*|/\\*[\\s\\S]*?\\*/",
        options: []
    )
    private static let hashCommentRegex = try? NSRegularExpression(pattern: "#[^\\n]*")
    private static let dashCommentRegex = try? NSRegularExpression(pattern: "--[^\\n]*")

    private static let hashLanguages: Set<String> = [
        "python", "py", "bash", "sh", "zsh", "shell", "console", "yaml", "yml", "ruby", "rb", "toml",
        "dockerfile", "docker", "r", "perl", "ini", "conf", "makefile", "make", "elixir", "ex",
    ]
    private static let dashLanguages: Set<String> = ["sql", "lua", "haskell", "hs"]

    static func highlight(_ code: String, language: String) -> AttributedString {
        let ns = code as NSString
        let length = ns.length
        guard length > 0, length <= 16_000 else {
            var plain = AttributedString(code)
            plain.foregroundColor = Palette.codeText
            return plain
        }

        var tokens = [UInt8](repeating: Token.plain.rawValue, count: length)
        let full = NSRange(location: 0, length: length)

        func mark(_ regex: NSRegularExpression?, _ token: Token) {
            guard let regex else { return }
            for match in regex.matches(in: code, options: [], range: full) {
                let r = match.range
                guard r.location != NSNotFound, r.length > 0 else { continue }
                let end = min(r.location + r.length, length)
                for k in r.location..<end { tokens[k] = token.rawValue }
            }
        }

        let lang = language.lowercased()
        mark(typeRegex, .type)
        mark(keywordRegex, .keyword)
        mark(numberRegex, .number)
        mark(stringRegex, .string)
        if hashLanguages.contains(lang) {
            mark(hashCommentRegex, .comment)
        } else if dashLanguages.contains(lang) {
            mark(dashCommentRegex, .comment)
        } else {
            mark(slashCommentRegex, .comment)
        }

        var result = AttributedString()
        var start = 0
        while start < length {
            let token = tokens[start]
            var end = start + 1
            while end < length && tokens[end] == token { end += 1 }
            var piece = AttributedString(ns.substring(with: NSRange(location: start, length: end - start)))
            piece.foregroundColor = color(for: Token(rawValue: token) ?? .plain)
            result.append(piece)
            start = end
        }
        return result
    }

    private static func color(for token: Token) -> Color {
        switch token {
        case .plain: return Palette.codeText
        case .keyword: return Color(hex: 0xB9A7FF)
        case .string: return Color(hex: 0x9FE0B8)
        case .number: return Color(hex: 0xF5C38B)
        case .comment: return Color(hex: 0x6E7385)
        case .type: return Color(hex: 0x8FCBFF)
        }
    }
}
