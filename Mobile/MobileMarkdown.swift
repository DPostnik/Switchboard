import SwiftUI
import UIKit

/// Assistant answers on the phone: the desktop's block parser rendered with native controls.
/// Rendering is data only: nothing is fetched (images stay links) and code is never run.
struct MarkdownMessageView: View {
    let text: String
    /// Accessibility identifier of the first block, so UI tests can find the message text.
    var identifier: String?
    var depth = 0

    var body: some View {
        let blocks = depth > 3 ? [.paragraph(text)] : MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block, depth: depth)
                    // Consecutive list items read as one list.
                    .padding(.top, index > 0 && block.isListItem && blocks[index - 1].isListItem ? -5 : 0)
                    .identified(index == 0 ? identifier : nil)
            }
        }
    }
}

private extension MarkdownBlock {
    var isListItem: Bool { if case .listItem = self { true } else { false } }
}

extension View {
    @ViewBuilder func identified(_ identifier: String?) -> some View {
        if let identifier { accessibilityIdentifier(identifier) } else { self }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let depth: Int

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(MarkdownInline.render(text)).font(.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            Text(MarkdownInline.render(text))
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 4).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let item):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let checked = item.checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                        .accessibilityLabel(checked ? L10n.text("Выполнено", "Done") : L10n.text("Не выполнено", "Not done"))
                } else if case .ordered(let number) = item.marker {
                    Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text(item.depth == 0 ? "•" : "◦").foregroundStyle(.secondary)
                }
                Text(MarkdownInline.render(item.text)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(min(item.depth, 4)) * 18)
        case .code(let code):
            CodeCard(code: code)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.35)).frame(width: 3)
                MarkdownMessageView(text: text, depth: depth + 1).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        case .callout(let callout):
            CalloutCard(callout: callout, depth: depth)
        case .table(let table):
            TableCard(table: table)
        case .rule:
            Divider().padding(.vertical, 4)
        case .image(let alt, let source):
            let title = alt.isEmpty ? L10n.text("Изображение", "Image") : alt
            if let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                // Opening is the user's choice; the phone never fetches agent-chosen images itself.
                Link(destination: url) { Label(title, systemImage: "photo") }.font(.subheadline)
            } else {
                Label(title + " · " + L10n.text("файл на Mac", "file on Mac"), systemImage: "photo")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        case .details(let summary, let body):
            DetailsBlock(summary: summary, text: body, depth: depth)
        case .footnote(let label, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label + ".").foregroundStyle(.secondary)
                Text(MarkdownInline.render(text))
            }.font(.caption)
        default:
            // Blocks added to the shared parser later (document metadata) are not part of chat answers.
            EmptyView()
        }
    }
}

private struct DetailsBlock: View {
    let summary: String
    let text: String
    let depth: Int
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            MarkdownMessageView(text: text, depth: depth + 1).padding(.top, 6)
        } label: {
            Text(MarkdownInline.render(summary)).font(.subheadline.weight(.semibold))
        }
    }
}

private struct CalloutCard: View {
    let callout: MarkdownCallout
    let depth: Int
    var body: some View {
        let style = Self.style(callout.kind)
        VStack(alignment: .leading, spacing: 6) {
            Label(callout.title ?? style.title, systemImage: style.icon)
                .font(.subheadline.weight(.semibold)).foregroundStyle(style.color)
            if !callout.body.isEmpty { MarkdownMessageView(text: callout.body, depth: depth + 1) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
    static func style(_ kind: MarkdownCallout.Kind) -> (title: String, icon: String, color: Color) {
        switch kind {
        case .note: (L10n.text("Заметка", "Note"), "info.circle", .blue)
        case .tip: (L10n.text("Совет", "Tip"), "lightbulb", .green)
        case .important: (L10n.text("Важно", "Important"), "exclamationmark.bubble", .purple)
        case .warning: (L10n.text("Внимание", "Warning"), "exclamationmark.triangle", .orange)
        case .caution: (L10n.text("Осторожно", "Caution"), "xmark.octagon", .red)
        }
    }
}

/// A copy control that confirms in place.
struct CopyControl: View {
    let title: String
    let text: String
    var identifier: String?
    @State private var copied = false
    var body: some View {
        Button {
            UIPasteboard.general.string = text
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            Label(copied ? L10n.text("Скопировано", "Copied") : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.medium))
        }.buttonStyle(.borderless).identified(identifier)
    }
}

struct CodeCard: View {
    let code: MarkdownCode
    @State private var expanded = false
    static let collapseAbove = 30, collapsedLines = 20, numberedFrom = 10

    var body: some View {
        let lines = MarkdownInline.highlightedLines(code)
        let collapsible = lines.count > Self.collapseAbove
        let shown = collapsible && !expanded ? Array(lines.prefix(Self.collapsedLines)) : lines
        let numbered = lines.count >= Self.numberedFrom
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(code.language.map { $0.lowercased() } ?? L10n.text("код", "code"))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                CopyControl(title: code.isShell && code.copyText != code.text ? L10n.text("Копировать команды", "Copy commands") : L10n.text("Копировать", "Copy"),
                            text: code.copyText, identifier: "copy-code")
            }.padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                        GridRow {
                            if numbered {
                                Text("\(index + 1)").foregroundStyle(.tertiary).gridColumnAlignment(.trailing)
                                    .accessibilityHidden(true)
                            }
                            Text(line.text).frame(maxWidth: .infinity, alignment: .leading)
                                .background { Rectangle().fill(line.change.map { ($0 ? Color.green : Color.red).opacity(0.14) } ?? .clear) }
                        }
                    }
                }
                .font(.system(.footnote, design: .monospaced))
                .padding(12)
            }
            if collapsible {
                Divider()
                Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                    Label(expanded ? L10n.text("Свернуть", "Collapse")
                                   : L10n.text("Показать ещё \(lines.count - Self.collapsedLines) строк", "Show \(lines.count - Self.collapsedLines) more lines"),
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderless).accessibilityIdentifier("toggle-code")
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5))
    }
}

struct TableCard: View {
    let table: MarkdownTable
    var body: some View {
        let alignments = table.displayAlignments
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("Таблица", "Table")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Markdown") { UIPasteboard.general.string = table.markdown }
                    Button(L10n.text("TSV (для таблиц)", "TSV (for spreadsheets)")) { UIPasteboard.general.string = table.tabSeparated }
                } label: {
                    Label(L10n.text("Копировать", "Copy"), systemImage: "doc.on.doc").font(.caption.weight(.medium))
                }.accessibilityIdentifier("copy-table")
            }.padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            // A narrow table fills the card; a wide one scrolls sideways.
            ViewThatFits(in: .horizontal) {
                grid(alignments).frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: false) { grid(alignments) }
            }
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.separator), lineWidth: 0.5))
    }
    private func grid(_ alignments: [MarkdownTable.Alignment]) -> some View {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { row, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                                Text(MarkdownInline.render(cell))
                                    .font(row == 0 ? .footnote.weight(.semibold) : .footnote).monospacedDigit()
                                    .lineLimit(4)
                                    .frame(maxWidth: 260, alignment: Self.alignment(column < alignments.count ? alignments[column] : .left))
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: Self.alignment(column < alignments.count ? alignments[column] : .left))
                                    .background { Rectangle().fill(row == 0 ? Color(.tertiarySystemFill) : row.isMultiple(of: 2) ? Color(.quaternarySystemFill) : .clear) }
                            }
                        }
                        if row == 0 { Divider() }
                    }
                }
    }
    static func alignment(_ value: MarkdownTable.Alignment) -> Alignment {
        switch value { case .left: .leading; case .center: .center; case .right: .trailing }
    }
}

/// Inline Markdown for one block: emphasis, code chips, links, highlights and footnote marks.
enum MarkdownInline {
    static let copyScheme = "contextdesk-copy"

    static func render(_ source: String) -> AttributedString {
        let prepared = footnoteMarks(source)
        var text = (try? AttributedString(markdown: prepared, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(prepared)
        // Inline code: a monospaced chip; a code span that names a file copies its path on tap.
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            let value = String(text[run.range].characters)
            text[run.range].font = .system(.callout, design: .monospaced)
            text[run.range].backgroundColor = Color(.tertiarySystemFill)
            if looksLikePath(value), let url = copyURL(value) { text[run.range].link = url }
        }
        highlightMarks(&text)
        linkBareURLs(&text)
        return text
    }

    /// One-line text for chat list previews.
    static func plain(_ source: String, limit: Int = 300) -> String {
        var parts: [String] = []
        for block in MarkdownBlocks.parse(String(source.prefix(4000))) {
            switch block {
            case .paragraph(let text), .heading(_, let text), .quote(let text), .footnote(_, let text): parts.append(text)
            case .listItem(let item): parts.append(item.text)
            case .callout(let callout): parts.append(callout.body)
            case .code(let code): parts.append(code.text.components(separatedBy: "\n").first ?? "")
            case .table(let table): parts.append((table.rows.first ?? []).joined(separator: " · "))
            case .image(let alt, _): parts.append(alt)
            case .details(let summary, _): parts.append(summary)
            default: break
            }
            if parts.joined().count > limit { break }
        }
        let line = parts.map { String(render($0).characters) }.joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return String(line.prefix(limit))
    }

    static func copyURL(_ value: String) -> URL? {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics).flatMap { URL(string: copyScheme + ":" + $0) }
    }
    static func copiedValue(_ url: URL) -> String? {
        guard url.scheme == copyScheme else { return nil }
        return String(url.absoluteString.dropFirst(copyScheme.count + 1)).removingPercentEncoding
    }

    /// A Markdown link to a file (`[plan](docs/plan.md)`, `file:///…`), not to a website.
    static func filePath(_ url: URL) -> String? {
        if url.scheme == "file" { return url.path.isEmpty ? nil : url.path }
        guard url.scheme == nil, url.host == nil else { return nil }
        let value = url.relativeString.removingPercentEncoding ?? url.relativeString
        return looksLikePath(value) ? value : nil
    }
    /// A path-like code span: `Sources/App.swift`, `~/notes.md`, `/tmp/log:12`. URLs are not paths.
    static func looksLikePath(_ value: String) -> Bool {
        guard value.count < 300, !value.contains("://"), !value.contains("\n") else { return false }
        if value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("./") || value.hasPrefix("../") { return value.count > 2 }
        return value.contains("/") && !value.contains(" ")
            && value.range(of: #"\.[A-Za-z0-9]{1,8}(:\d+)?$"#, options: .regularExpression) != nil
    }

    /// Short link text: host and path, without scheme and `www.`.
    static func shortened(_ url: URL, limit: Int = 40) -> String {
        var value = (url.host ?? url.absoluteString) + url.path
        if value.hasPrefix("www.") { value.removeFirst(4) }
        if value.hasSuffix("/") { value.removeLast() }
        return value.count > limit ? String(value.prefix(limit - 1)) + "…" : value
    }

    private static func footnoteMarks(_ source: String) -> String {
        guard source.contains("[^") else { return source }
        let digits: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]
        var result = source
        let pattern = try! NSRegularExpression(pattern: #"\[\^([^\]\s]{1,12})\]"#)
        for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let whole = Range(match.range, in: result), let label = Range(match.range(at: 1), in: result) else { continue }
            let value = String(result[label])
            let mark = value.allSatisfy(\.isNumber) ? String(value.compactMap { digits[$0] }) : "[" + value + "]"
            result.replaceSubrange(whole, with: mark)
        }
        return result
    }

    private static func highlightMarks(_ text: inout AttributedString) {
        let plain = String(text.characters)
        guard plain.contains("==") else { return }
        let pattern = try! NSRegularExpression(pattern: #"==([^=\n]+)=="#)
        for match in pattern.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).reversed() {
            guard let whole = range(match.range, in: plain, of: text), let inner = range(match.range(at: 1), in: plain, of: text) else { continue }
            var marked = AttributedString(text[inner])
            marked.backgroundColor = Color.yellow.opacity(0.35)
            text.replaceSubrange(whole, with: marked)
        }
    }

    private static func linkBareURLs(_ text: inout AttributedString) {
        // Autolinked URLs show the address itself; shorten those, keep authored link text.
        for run in text.runs.reversed() {
            guard let url = run.link, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  String(text[run.range].characters) == url.absoluteString else { continue }
            var link = AttributedString(shortened(url))
            link.link = url
            text.replaceSubrange(run.range, with: link)
        }
        let plain = String(text.characters)
        guard plain.contains("http"), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).reversed() {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let target = range(match.range, in: plain, of: text) else { continue }
            if text[target].runs.contains(where: { $0.link != nil }) { continue }
            var link = AttributedString(shortened(url))
            link.link = url
            text.replaceSubrange(target, with: link)
        }
    }

    private static func range(_ range: NSRange, in plain: String, of text: AttributedString) -> Range<AttributedString.Index>? {
        guard let found = Range(range, in: plain) else { return nil }
        let start = text.characters.index(text.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: found.lowerBound))
        let end = text.characters.index(start, offsetBy: plain.distance(from: found.lowerBound, to: found.upperBound))
        return start..<end
    }

    struct CodeLine { var text: AttributedString; var change: Bool? }

    /// Code split into highlighted lines; diff lines carry their change (true added, false removed).
    static func highlightedLines(_ code: MarkdownCode) -> [CodeLine] {
        let lines = code.text.components(separatedBy: "\n")
        var styled = AttributedString(code.text)
        if code.text.utf16.count <= SyntaxHighlighter.limit, !code.isDiff {
            for token in SyntaxHighlighter.tokens(in: code.text, language: code.language) {
                guard let target = range(token.range, in: code.text, of: styled) else { continue }
                styled[target].foregroundColor = color(token.kind)
            }
        }
        var result: [CodeLine] = []
        var cursor = styled.startIndex
        for line in lines {
            let end = styled.characters.index(cursor, offsetBy: line.count)
            var value = AttributedString(styled[cursor..<end])
            if value.characters.isEmpty { value = AttributedString(" ") }
            let change: Bool? = code.isDiff && !line.hasPrefix("+++") && !line.hasPrefix("---")
                ? (line.hasPrefix("+") ? true : line.hasPrefix("-") ? false : nil) : nil
            result.append(CodeLine(text: value, change: change))
            cursor = end < styled.endIndex ? styled.characters.index(after: end) : end
        }
        return result
    }

    private static func color(_ kind: SyntaxHighlighter.Kind) -> Color {
        switch kind {
        case .keyword: Color(.systemPink)
        case .string: Color(.systemRed)
        case .comment: Color(.secondaryLabel)
        case .number: Color(.systemBlue)
        case .type: Color(.systemTeal)
        case .key: Color(.systemIndigo)
        case .variable: Color(.systemPurple)
        case .attribute: Color(.systemBrown)
        }
    }
}
