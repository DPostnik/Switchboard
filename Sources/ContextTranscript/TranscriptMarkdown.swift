import AppKit
import ContextCore

extension NSAttributedString.Key {
    /// Paragraph style a block chose for itself; message styling restores it after applying the base style.
    static let blockParagraphStyle = NSAttributedString.Key("ContextDeskBlockParagraphStyle")
    /// Distance from the trailing edge of the column to a right-aligned tab stop (controls on block headers).
    static let rightTabInset = NSAttributedString.Key("ContextDeskRightTabInset")
    static let codeCard = NSAttributedString.Key("ContextDeskCodeCard")
    static let codeLineNumber = NSAttributedString.Key("ContextDeskCodeLineNumber")
    static let diffLine = NSAttributedString.Key("ContextDeskDiffLine")
    static let calloutCard = NSAttributedString.Key("ContextDeskCalloutCard")
    static let horizontalRule = NSAttributedString.Key("ContextDeskHorizontalRule")
    static let sectionKey = NSAttributedString.Key("ContextDeskSection")
    static let blockCopy = NSAttributedString.Key("ContextDeskBlockCopy")
    static let tableData = NSAttributedString.Key("ContextDeskTableData")
    /// Slug of a heading, the target of `#anchor` links.
    static let headingSlug = NSAttributedString.Key("ContextDeskHeadingSlug")
}

final class TableBox: NSObject {
    let table: MarkdownTable
    init(_ table: MarkdownTable) { self.table = table }
}

/// Renders one assistant answer as native text blocks. All controls are links
/// handled by the transcript view; nothing is fetched or executed while rendering.
@MainActor struct TranscriptMarkdown {
    static let codeCollapseThreshold = 30
    static let codeCollapsedLines = 20
    static let lineNumberThreshold = 10
    static let sourcesThreshold = 3
    static let cardPadding: CGFloat = 14
    static let gutter: CGFloat = 30

    let view: TranscriptScrollView
    let item: TranscriptItem
    let options: TranscriptLinks.Options
    let width: CGFloat
    private var copyIndex = 0
    private var blockCounter = 0
    private let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]

    init(view: TranscriptScrollView, item: TranscriptItem, options: TranscriptLinks.Options, width: CGFloat) {
        self.view = view; self.item = item; self.options = options; self.width = width
    }

    mutating func render(into result: NSMutableAttributedString) {
        let nodes = MarkdownBlocks.nodes(item.text)
        let lines = MarkdownBlocks.lines(item.text)
        var section: String?
        for (index, node) in nodes.enumerated() {
            let start = result.length
            var sectionCopy: (String, String)?
            if case .heading = node.block {
                section = "\(item.id)#s\(index)"
                sectionCopy = (section!, MarkdownBlocks.section(of: nodes, at: index, lines: lines))
            }
            let next = index + 1 < nodes.count ? nodes[index + 1].block : nil
            renderBlock(node.block, next: next, into: result, indent: 0, tail: -4, sectionCopy: sectionCopy)
            if let section, result.length > start {
                result.addAttribute(.sectionKey, value: section, range: NSRange(location: start, length: result.length - start))
            }
        }
        if !view.isDocument { appendSources(into: result, nodes: nodes, lines: lines) }
    }

    // MARK: Blocks

    private mutating func renderBlocks(_ source: String, into result: NSMutableAttributedString, indent: CGFloat, tail: CGFloat) {
        let blocks = MarkdownBlocks.parse(source)
        for (index, block) in blocks.enumerated() {
            renderBlock(block, next: index + 1 < blocks.count ? blocks[index + 1] : nil, into: result,
                        indent: indent, tail: tail, sectionCopy: nil)
        }
    }

    private mutating func renderBlock(_ block: MarkdownBlock, next: MarkdownBlock?, into result: NSMutableAttributedString,
                                      indent: CGFloat, tail: CGFloat, sectionCopy: (String, String)?) {
        let first = isAtBodyStart(result)
        switch block {
        case .paragraph(let text):
            append(inline(text), to: result, style: paragraph(indent, tail), after: 10)
        case .heading(let level, let text):
            renderHeading(level: level, text: text, into: result, indent: indent, tail: tail, sectionCopy: sectionCopy, first: first)
        case .listItem(let listItem):
            renderListItem(listItem, isLast: { if case .listItem = next { return false }; return true }(),
                           into: result, indent: indent, tail: tail)
        case .code(let code):
            renderCode(code, into: result, indent: indent, tail: tail)
        case .quote(let text):
            renderQuote(text, into: result, indent: indent, tail: tail)
        case .callout(let callout):
            renderCallout(callout, into: result, indent: indent, tail: tail)
        case .table(let table):
            renderTable(table, into: result, indent: indent, tail: tail)
        case .rule:
            let style = paragraph(indent, tail) { $0.minimumLineHeight = 18; $0.maximumLineHeight = 18; $0.lineSpacing = 0 }
            let range = append(NSAttributedString(string: "\u{00A0}", attributes: [.font: NSFont.systemFont(ofSize: 6)]),
                               to: result, style: style, after: 10, before: 2)
            result.addAttribute(.horizontalRule, value: true, range: range)
        case .image(let alt, let source):
            renderImage(alt: alt, source: source, into: result, indent: indent, tail: tail)
        case .details(let summary, let detailsBody):
            let key = nextKey("d")
            let open = view.expandedBlocks.contains(key)
            let title = summary.isEmpty ? L10n.text("Подробнее", "Details") : summary
            let line = NSMutableAttributedString(string: (open ? "▾ " : "▸ "), attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor
            ])
            line.append(inline(title, font: NSFont.systemFont(ofSize: 14, weight: .medium)))
            line.addAttributes([.link: "contextdesk-toggle:" + key], range: NSRange(location: 0, length: line.length))
            append(line, to: result, style: paragraph(indent, tail), after: open ? 6 : 10)
            if open {
                renderBlocks(detailsBody, into: result, indent: indent + 16, tail: tail)
            }
        case .properties(let properties):
            renderProperties(properties, into: result, indent: indent, tail: tail)
        case .footnote(let label, let text):
            let line = NSMutableAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .baselineOffset: 4, .foregroundColor: NSColor.controlAccentColor
            ])
            line.append(NSAttributedString(string: " "))
            line.append(inline(text, font: NSFont.systemFont(ofSize: 12), color: .secondaryLabelColor))
            append(line, to: result, style: paragraph(indent, tail) { $0.lineSpacing = 2 }, after: 4)
        }
    }

    private func isAtBodyStart(_ result: NSAttributedString) -> Bool {
        // Headings at the very top of an answer need no extra space above them.
        guard result.length > 0 else { return true }
        return result.attribute(.responseHeader, at: result.length - 1, effectiveRange: nil) != nil
    }

    private mutating func renderHeading(level: Int, text: String, into result: NSMutableAttributedString,
                                        indent: CGFloat, tail: CGFloat, sectionCopy: (String, String)?, first: Bool) {
        let sizes: [CGFloat] = [21, 18, 15.5, 14, 14, 14]
        let font = NSFont.systemFont(ofSize: sizes[min(level, 6) - 1], weight: level <= 1 ? .bold : .semibold)
        let line = NSMutableAttributedString(attributedString: inline(text, font: font,
                                                                      color: level >= 4 ? .secondaryLabelColor : .labelColor))
        if let (key, source) = sectionCopy, !source.isEmpty {
            let index = copyIndex; copyIndex += 1
            let feedback = view.copyFeedback.flatMap { $0.id == item.id && $0.block == index ? $0.succeeded : nil }
            line.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            line.append(view.copyControl(feedback: feedback,
                                         description: L10n.text("Скопировать раздел в Markdown", "Copy this section as Markdown"),
                                         visible: { [weak view] in view?.hoveredSection == key },
                                         attributes: [.link: "contextdesk-block-copy", .blockCopy: source, .quoteIndex: index]))
        }
        let before: CGFloat = first ? 2 : [18, 16, 12, 10, 10, 10][min(level, 6) - 1]
        let range = append(line, to: result, style: paragraph(indent, tail) { $0.lineSpacing = 2 }, after: level <= 2 ? 8 : 6, before: before)
        result.addAttribute(.headingSlug, value: TranscriptLinks.slug(TranscriptLinks.render(text, attributes: [:]).string),
                            range: NSRange(location: range.location, length: 1))
    }

    private mutating func renderListItem(_ listItem: MarkdownListItem, isLast: Bool, into result: NSMutableAttributedString,
                                         indent: CGFloat, tail: CGFloat) {
        let level = indent + CGFloat(listItem.depth) * 20
        let markerWidth: CGFloat
        let line = NSMutableAttributedString()
        if let checked = listItem.checked {
            markerWidth = 22
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: checked ? "checkmark.square.fill" : "square",
                                       accessibilityDescription: checked ? L10n.text("Выполнено", "Done") : L10n.text("Не выполнено", "Not done"))?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)
                    .applying(.init(paletteColors: [checked ? .controlAccentColor : .secondaryLabelColor])))
            attachment.bounds = NSRect(x: 0, y: -2.5, width: 15, height: 15)
            line.append(NSAttributedString(attachment: attachment))
        } else {
            switch listItem.marker {
            case .bullet:
                markerWidth = 18
                let bullets = ["•", "◦", "▪︎"]
                line.append(NSAttributedString(string: bullets[listItem.depth % bullets.count], attributes: [
                    .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor
                ]))
            case .ordered(let number):
                markerWidth = number >= 100 ? 36 : number >= 10 ? 28 : 22
                line.append(NSAttributedString(string: "\(number).", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor
                ]))
            }
        }
        line.append(NSAttributedString(string: "\t", attributes: body))
        line.append(inline(listItem.text, color: listItem.checked == true ? .secondaryLabelColor : .labelColor))
        let textIndent = level + markerWidth
        let style = paragraph(level, tail) {
            $0.headIndent = textIndent
            $0.tabStops = [NSTextTab(textAlignment: .left, location: textIndent)]
            $0.defaultTabInterval = 0
        }
        let continuation = paragraph(textIndent, tail)
        append(line, to: result, style: style, after: isLast ? 10 : 4, continuation: continuation)
    }

    private mutating func renderCode(_ code: MarkdownCode, into result: NSMutableAttributedString, indent: CGFloat, tail: CGFloat) {
        let key = nextKey("c")
        let index = copyIndex; copyIndex += 1
        let start = result.length
        let pad = Self.cardPadding
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var lines = code.text.components(separatedBy: "\n")
        if lines.last == "", lines.count > 1, !code.closed { lines.removeLast() }
        let collapsible = !view.isDocument && lines.count > Self.codeCollapseThreshold
        let expanded = view.expandedBlocks.contains(key)
        let shown = collapsible && !expanded ? Array(lines.prefix(Self.codeCollapsedLines)) : lines
        let numbered = lines.count >= Self.lineNumberThreshold && !code.isDiff

        // Header: language on the left, copy on the right.
        let header = NSMutableAttributedString(string: code.language ?? L10n.text("код", "code"), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor
        ])
        header.append(NSAttributedString(string: "\t", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        let copyText = code.copyText
        let feedback = view.copyFeedback.flatMap { $0.id == item.id && $0.block == index ? $0.succeeded : nil }
        let commandsOnly = copyText != code.text
        header.append(view.copyControl(
            feedback: feedback,
            description: commandsOnly ? L10n.text("Скопировать команды без приглашения и вывода", "Copy the commands without prompts or output")
                                      : L10n.text("Скопировать код", "Copy the code"),
            label: commandsOnly ? L10n.text("Копировать команды", "Copy commands") : L10n.text("Копировать", "Copy"),
            attributes: [.link: "contextdesk-block-copy", .blockCopy: copyText, .quoteIndex: index]))
        let headerRange = append(header, to: result, style: paragraph(indent + pad, tail - pad) {
            $0.lineSpacing = 0; $0.minimumLineHeight = 22
        }, after: 8, before: 6)
        result.addAttribute(.rightTabInset, value: -(tail - pad), range: headerRange)

        // Body: highlighted, optionally numbered, diff lines tinted.
        let text = shown.joined(separator: "\n")
        let codeText = NSMutableAttributedString(string: text, attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
        if code.isDiff {
            var location = 0
            for line in shown {
                let length = (line as NSString).length
                let range = NSRange(location: location, length: length)
                if line.hasPrefix("+"), !line.hasPrefix("+++") {
                    codeText.addAttributes([.diffLine: "+", .foregroundColor: NSColor.systemGreen.blended(withFraction: 0.35, of: .labelColor) ?? .labelColor], range: range)
                } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                    codeText.addAttributes([.diffLine: "-", .foregroundColor: NSColor.systemRed.blended(withFraction: 0.35, of: .labelColor) ?? .labelColor], range: range)
                } else if line.hasPrefix("@@") {
                    codeText.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: range)
                } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                    codeText.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                }
                location += length + 1
            }
        } else {
            for token in SyntaxHighlighter.tokens(in: text, language: code.language) where NSMaxRange(token.range) <= codeText.length {
                codeText.addAttribute(.foregroundColor, value: Self.color(token.kind), range: token.range)
            }
        }
        if numbered {
            var location = 0
            for (number, line) in shown.enumerated() {
                let length = (line as NSString).length
                // Empty lines carry the number on their newline.
                if location < codeText.length || number == 0 {
                    codeText.addAttribute(.codeLineNumber, value: number + 1,
                                          range: NSRange(location: min(location, max(0, codeText.length - 1)), length: codeText.length > 0 ? 1 : 0))
                }
                location += length + 1
            }
        }
        if codeText.length == 0 { codeText.append(NSAttributedString(string: " ", attributes: [.font: mono])) }
        let bodyIndent = indent + pad + (numbered ? Self.gutter : 0)
        append(codeText, to: result, style: paragraph(bodyIndent, tail - pad) {
            $0.lineSpacing = 2; $0.lineBreakMode = .byCharWrapping
        }, after: collapsible ? 4 : 0)

        if collapsible {
            let hidden = lines.count - shown.count
            let title = expanded ? L10n.text("Свернуть", "Collapse")
                                 : L10n.text("Показать ещё \(hidden) \(Self.russianLines(hidden))", "Show \(hidden) more \(hidden == 1 ? "line" : "lines")")
            let toggle = NSAttributedString(string: (expanded ? "▴ " : "▾ ") + title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.controlAccentColor,
                .link: "contextdesk-toggle:" + key
            ])
            append(toggle, to: result, style: paragraph(indent + pad, tail - pad) { $0.lineSpacing = 0 }, after: 0)
        }
        result.addAttribute(.codeCard, value: key, range: NSRange(location: start, length: result.length - start))
        appendSpacer(to: result, height: 20)
    }

    private mutating func renderQuote(_ text: String, into result: NSMutableAttributedString, indent: CGFloat, tail: CGFloat) {
        let index = copyIndex; copyIndex += 1
        let start = result.length
        let pad: CGFloat = 16
        // The pasteboard gets the visible text without Markdown marks or link targets.
        let plain = TranscriptLinks.render(text, attributes: [:]).string
        let feedback = view.copyFeedback.flatMap { $0.id == item.id && $0.block == index ? $0.succeeded : nil }
        let controlAttributes: [NSAttributedString.Key: Any] = [.link: "contextdesk-quote-copy", .quoteCopy: plain, .quoteIndex: index]
        let control = NSMutableAttributedString(attributedString: view.copyControl(
            feedback: feedback, description: L10n.text("Скопировать текст блока", "Copy the block text"),
            label: L10n.text("Копировать", "Copy"), attributes: controlAttributes))
        var body = NSMutableAttributedString()
        renderBlocks(text, into: body, indent: indent + pad, tail: tail - pad)
        // The control sits at the trailing edge of the first line when that line leaves room for it;
        // otherwise it gets its own row above the text so it never overlaps the text.
        let string = body.string as NSString
        let first = string.paragraphRange(for: NSRange(location: 0, length: 0))
        let content = NSRange(location: first.location, length: max(0, first.length - 1))
        let available = width - 10 - (indent + pad) + (tail - pad)
        let lineWidth = body.attributedSubstring(from: content).size().width
        if body.length > 0, !string.substring(with: content).contains("\t"),
           lineWidth + control.size().width + 24 <= available,
           let style = (body.attribute(.blockParagraphStyle, at: first.location, effectiveRange: nil) as? NSParagraphStyle)?
               .mutableCopy() as? NSMutableParagraphStyle {
            let font = content.length > 0 ? body.attribute(.font, at: content.location, effectiveRange: nil) ?? self.body[.font]! : self.body[.font]!
            let inline = NSMutableAttributedString(string: "\t", attributes: [.font: font])
            inline.append(control)
            body.insert(inline, at: NSMaxRange(content))
            let line = NSRange(location: first.location, length: first.length + inline.length)
            body.addAttributes([.paragraphStyle: style, .blockParagraphStyle: style, .rightTabInset: -(tail - pad)], range: line)
            // Spacing before a paragraph is outside the card's drawn area; a short spacer row pads the top.
            let spacer = paragraph(indent + pad, tail - pad) { $0.minimumLineHeight = 12; $0.maximumLineHeight = 12; $0.lineSpacing = 0; $0.paragraphSpacingBefore = 8 }
            body.insert(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4),
                                                                      .paragraphStyle: spacer, .blockParagraphStyle: spacer]), at: 0)
        } else {
            // Keep the control paragraph aligned as one unit, including its newline.
            control.append(NSAttributedString(string: "\n", attributes: controlAttributes))
            let spacer = paragraph(indent + pad, tail - pad) { $0.minimumLineHeight = 8; $0.maximumLineHeight = 8; $0.lineSpacing = 0; $0.paragraphSpacingBefore = 8 }
            let header = NSMutableAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4),
                                                                              .paragraphStyle: spacer, .blockParagraphStyle: spacer])
            append(control, to: header, style: paragraph(indent + pad, tail - pad) {
                $0.alignment = .right; $0.lineSpacing = 0
            }, after: 2)
            header.append(body)
            body = header
        }
        result.append(body)
        trimTrailingSpacing(result, from: start, to: 0)
        result.addAttribute(.quoteCard, value: index, range: NSRange(location: start, length: result.length - start))
        appendSpacer(to: result, height: 20)
    }

    private mutating func renderCallout(_ callout: MarkdownCallout, into result: NSMutableAttributedString, indent: CGFloat, tail: CGFloat) {
        let key = nextKey("n")
        let start = result.length
        let pad: CGFloat = 16
        let (symbol, color, title) = Self.calloutStyle(callout.kind)
        let line = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [color])))
        attachment.bounds = NSRect(x: 0, y: -2.5, width: 15, height: 15)
        line.append(NSAttributedString(attachment: attachment))
        line.append(NSAttributedString(string: "  ", attributes: body))
        line.append(inline(callout.title ?? title, font: NSFont.systemFont(ofSize: 13, weight: .semibold), color: color))
        append(line, to: result, style: paragraph(indent + pad, tail - pad) { $0.lineSpacing = 0 }, after: 4, before: 10)
        renderBlocks(callout.body, into: result, indent: indent + pad, tail: tail - pad)
        trimTrailingSpacing(result, from: start, to: 0)
        result.addAttribute(.calloutCard, value: callout.kind.rawValue + "|" + key, range: NSRange(location: start, length: result.length - start))
        appendSpacer(to: result, height: 20)
    }

    /// Front matter as a quiet two-column card; tags read as `#tag`.
    private mutating func renderProperties(_ properties: [MarkdownProperty], into result: NSMutableAttributedString,
                                           indent: CGFloat, tail: CGFloat) {
        let key = nextKey("p")
        let start = result.length
        let pad = Self.cardPadding
        let nameWidth = min(160, max(70, properties.map { ($0.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width }.max() ?? 0) + 16)
        let spacer = paragraph(indent + pad, tail - pad) { $0.minimumLineHeight = 8; $0.maximumLineHeight = 8; $0.lineSpacing = 0 }
        result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: spacer, .blockParagraphStyle: spacer]))
        for (number, property) in properties.enumerated() {
            let line = NSMutableAttributedString(string: property.name + "\t", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
            ])
            let isTags = ["tags", "tag", "aliases"].contains(property.name.lowercased())
            if property.values.isEmpty {
                line.append(NSAttributedString(string: "—", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            for (offset, value) in property.values.enumerated() {
                if offset > 0 { line.append(NSAttributedString(string: isTags ? "  " : ", ", attributes: [.font: NSFont.systemFont(ofSize: 13)])) }
                if isTags {
                    line.append(NSAttributedString(string: (property.name.lowercased() == "aliases" ? "" : "#") + value.trimmingCharacters(in: CharacterSet(charactersIn: "#")), attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.controlAccentColor,
                        .inlineChip: TranscriptLinks.Chip.file.rawValue
                    ]))
                } else {
                    line.append(inline(value, font: NSFont.systemFont(ofSize: 13)))
                }
            }
            append(line, to: result, style: paragraph(indent + pad, tail - pad) {
                $0.headIndent = indent + pad + nameWidth
                $0.tabStops = [NSTextTab(textAlignment: .left, location: indent + pad + nameWidth)]
                $0.lineSpacing = 2
            }, after: number == properties.count - 1 ? 0 : 3)
        }
        result.addAttribute(.codeCard, value: key, range: NSRange(location: start, length: result.length - start))
        appendSpacer(to: result, height: 20)
    }

    static let tableRowLimit = 100

    private mutating func renderTable(_ table: MarkdownTable, into result: NSMutableAttributedString, indent: CGFloat, tail: CGFloat) {
        let tableKey = nextKey("t")
        let index = copyIndex; copyIndex += 1
        let feedback = view.copyFeedback.flatMap { $0.id == item.id && $0.block == index ? $0.succeeded : nil }
        let small = NSFont.systemFont(ofSize: 11, weight: .medium)
        let toolbar = NSMutableAttributedString()
        let box = TableBox(table)
        func action(_ symbol: String, _ title: String, _ link: String, tooltip: String) {
            if toolbar.length > 0 { toolbar.append(NSAttributedString(string: "   ", attributes: [.font: small])) }
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium).applying(.init(paletteColors: [.secondaryLabelColor])))
            attachment.bounds = NSRect(x: 0, y: -1.5, width: 12, height: 12)
            let part = NSMutableAttributedString(attachment: attachment)
            part.append(NSAttributedString(string: " " + title, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
            part.addAttributes([.link: link, .tableData: box, .quoteIndex: index, .toolTip: tooltip], range: NSRange(location: 0, length: part.length))
            toolbar.append(part)
        }
        do {
            action("doc.on.doc", "Markdown", "contextdesk-table:md", tooltip: L10n.text("Скопировать таблицу в Markdown", "Copy the table as Markdown"))
            action("tablecells", "TSV", "contextdesk-table:tsv",
                   tooltip: L10n.text("Скопировать для Numbers и Excel (значения через табуляцию)", "Copy for Numbers and Excel (tab-separated values)"))
            action("arrow.up.left.and.arrow.down.right", L10n.text("Открыть", "Open"), "contextdesk-table:open",
                   tooltip: L10n.text("Открыть таблицу в отдельном окне с прокруткой", "Open the table in a separate scrollable window"))
        }
        if let feedback {
            toolbar.insert(NSAttributedString(string: (feedback ? "✓ " + L10n.text("Скопировано", "Copied") : L10n.text("Не удалось скопировать", "Could not copy")) + "   ",
                                              attributes: [.font: small, .foregroundColor: feedback ? NSColor.systemGreen : NSColor.systemRed]), at: 0)
        }
        append(toolbar, to: result, style: paragraph(indent, tail) { $0.alignment = .right; $0.lineSpacing = 0 }, after: 4, before: 4)
        let start = result.length
        // Very long tables show their first rows until expanded; copy and the window keep every row.
        let limited = table.rows.count > Self.tableRowLimit + 1 && !view.expandedBlocks.contains(tableKey)
        let shown = limited ? MarkdownTable(rows: Array(table.rows.prefix(Self.tableRowLimit + 1)), alignments: table.alignments) : table
        result.append(TranscriptTables.render(shown, attributes: body, options: options))
        if table.rows.count > Self.tableRowLimit + 1 {
            let total = table.rows.count - 1
            let title = limited ? L10n.text("Показать все \(total) \(Self.russianLines(total))", "Show all \(total) rows")
                                : L10n.text("Свернуть до \(Self.tableRowLimit) строк", "Collapse to \(Self.tableRowLimit) rows")
            append(NSAttributedString(string: (limited ? "▾ " : "▴ ") + title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.controlAccentColor,
                .link: "contextdesk-toggle:" + tableKey
            ]), to: result, style: paragraph(indent, tail) { $0.lineSpacing = 0 }, after: 0, before: 6)
        }
        // Table paragraphs keep their own styles; keep a gap after the table.
        if result.length > start { appendSpacer(to: result, height: 8) }
    }

    private mutating func renderImage(alt: String, source: String, into result: NSMutableAttributedString, indent: CGFloat, tail: CGFloat) {
        let url: URL?
        if source.hasPrefix("http://") || source.hasPrefix("https://") { url = TranscriptLinks.destination(source) }
        else if let file = TranscriptLinks.fileReference(source.removingPercentEncoding ?? source, options: options) { url = file.url }
        else if let base = options.baseDirectory, !source.contains("://"),
                case let candidate = URL(fileURLWithPath: source.removingPercentEncoding ?? source, relativeTo: base).standardizedFileURL,
                options.fileExists(candidate.path) { url = candidate }
        else if source.hasPrefix("file://"), let fileURL = URL(string: source), FileManager.default.fileExists(atPath: fileURL.path) { url = fileURL }
        else { url = nil }
        if let url, url.isFileURL, let image = Self.image(at: url) {
            let maxWidth = min(520, max(120, width + tail - indent - 8)), maxHeight: CGFloat = 420
            let scale = min(1, maxWidth / max(1, image.size.width), maxHeight / max(1, image.size.height))
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: 0, width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
            let line = NSMutableAttributedString(attachment: attachment)
            line.addAttributes([.link: url, .toolTip: url.path + "\n" + L10n.text("Нажмите, чтобы открыть", "Click to open")],
                               range: NSRange(location: 0, length: line.length))
            append(line, to: result, style: paragraph(indent, tail) { $0.lineSpacing = 0 }, after: alt.isEmpty ? 10 : 2, before: 4)
            if !alt.isEmpty {
                append(NSAttributedString(string: alt, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]),
                       to: result, style: paragraph(indent, tail), after: 10)
            }
            return
        }
        // Remote images are never downloaded; they stay a link the user can open.
        let line = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: "photo", accessibilityDescription: L10n.text("Изображение", "Image"))?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor])))
        attachment.bounds = NSRect(x: 0, y: -2, width: 15, height: 13)
        line.append(NSAttributedString(attachment: attachment))
        let title = alt.isEmpty ? (url?.lastPathComponent ?? source) : alt
        var style = body
        if let url { style[.link] = url; style[.foregroundColor] = NSColor.linkColor; style[.toolTip] = url.absoluteString }
        else { style[.foregroundColor] = NSColor.secondaryLabelColor; style[.toolTip] = L10n.text("Изображение не найдено: ", "Image not found: ") + source }
        line.append(NSAttributedString(string: " " + title, attributes: style))
        append(line, to: result, style: paragraph(indent, tail), after: 10)
    }

    /// A collapsed list of the web pages an answer links to.
    private mutating func appendSources(into result: NSMutableAttributedString, nodes: [MarkdownNode], lines: [String]) {
        let sources = Self.webSources(in: item.text, nodes: nodes, lines: lines)
        guard sources.count >= Self.sourcesThreshold else { return }
        let key = item.id + "#sources"
        let open = view.expandedBlocks.contains(key)
        let title = (open ? "▾ " : "▸ ") + L10n.text("Источники · \(sources.count)", "Sources · \(sources.count)")
        append(NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
            .link: "contextdesk-toggle:" + key
        ]), to: result, style: paragraph(0, -4) { $0.lineSpacing = 0 }, after: open ? 4 : 6, before: 4)
        guard open else { return }
        for (number, source) in sources.enumerated() {
            let line = NSMutableAttributedString(string: "\(number + 1).\t", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor
            ])
            let host = source.url.host?.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression) ?? source.url.absoluteString
            line.append(NSAttributedString(string: host, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.linkColor,
                .link: source.url, .toolTip: source.url.absoluteString
            ]))
            if let title = source.title, title != host, title != source.url.absoluteString {
                line.append(NSAttributedString(string: " — " + title, attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
                ]))
            }
            append(line, to: result, style: paragraph(4, -4) {
                $0.headIndent = 28; $0.tabStops = [NSTextTab(textAlignment: .left, location: 28)]; $0.lineSpacing = 1
            }, after: number == sources.count - 1 ? 6 : 2)
        }
    }

    /// Web pages the answer links to, in order of first appearance. Parses the Markdown once more;
    /// the renderer passes its own nodes and lines to the other overload instead.
    nonisolated static func webSources(in text: String) -> [(url: URL, title: String?)] {
        if let cached = WebSourceScan.cached(text) { return cached }
        return webSources(in: text, nodes: MarkdownBlocks.nodes(text), lines: MarkdownBlocks.lines(text))
    }

    /// `nodes` and `lines` must come from `MarkdownBlocks.nodes(text)` and `MarkdownBlocks.lines(text)`.
    /// The result is memoized by the exact text: a message re-renders many times (every streaming tick, each
    /// toggle, the re-render when a turn finishes) and the link detector is the expensive part.
    nonisolated static func webSources(in text: String, nodes: [MarkdownNode], lines: [String]) -> [(url: URL, title: String?)] {
        if let cached = WebSourceScan.cached(text) { return cached }
        var result: [(url: URL, title: String?)] = []
        var seen = Set<String>()
        func add(_ url: URL, _ title: String?) {
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return }
            var key = url.absoluteString
            if key.hasSuffix("/") { key.removeLast() }
            if seen.insert(key).inserted { result.append((url, title)) }
        }
        // Code blocks are literal and are not sources.
        let prose = nodes.compactMap { node -> String? in
            if case .code = node.block { return nil }
            guard node.lines.lowerBound >= 0, node.lines.upperBound <= lines.count else { return nil }
            return lines[node.lines].joined(separator: "\n")
        }.joined(separator: "\n")
        let ns = prose as NSString
        var linked = Set<Int>()
        if let markdownLink = WebSourceScan.markdownLink {
            for match in markdownLink.matches(in: prose, range: NSRange(location: 0, length: ns.length)) {
                if let url = URL(string: ns.substring(with: match.range(at: 2))) { add(url, ns.substring(with: match.range(at: 1))) }
                for offset in 0..<match.range.length { linked.insert(match.range.location + offset) }
            }
        }
        if let detector = WebSourceScan.detector {
            for match in detector.matches(in: prose, range: NSRange(location: 0, length: ns.length)) where !linked.contains(match.range.location) {
                if let url = match.url { add(url, nil) }
            }
        }
        WebSourceScan.remember(text, result)
        return result
    }

    // MARK: Helpers

    private mutating func nextKey(_ kind: String) -> String {
        defer { blockCounter += 1 }
        return "\(item.id)#\(kind)\(blockCounter)"
    }

    private func inline(_ text: String, font: NSFont = .systemFont(ofSize: 14), color: NSColor = .labelColor) -> NSAttributedString {
        TranscriptLinks.render(text, attributes: [.font: font, .foregroundColor: color], options: options)
    }

    private func paragraph(_ indent: CGFloat, _ tail: CGFloat, _ configure: (NSMutableParagraphStyle) -> Void = { _ in }) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.lineBreakMode = .byWordWrapping
        style.firstLineHeadIndent = indent; style.headIndent = indent; style.tailIndent = tail
        configure(style)
        return style
    }

    /// Appends a block, ending it with a newline. The first paragraph gets `before`, the last gets `after`.
    @discardableResult
    private func append(_ text: NSAttributedString, to result: NSMutableAttributedString, style: NSParagraphStyle,
                        after: CGFloat, before: CGFloat = 0, continuation: NSParagraphStyle? = nil) -> NSRange {
        let block = NSMutableAttributedString(attributedString: text)
        if !block.string.hasSuffix("\n") {
            let font = block.length > 0 ? block.attribute(.font, at: block.length - 1, effectiveRange: nil) ?? body[.font]! : body[.font]!
            block.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        }
        let string = block.string as NSString
        var paragraphs: [NSRange] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            paragraphs.append(enclosing)
        }
        for (index, range) in paragraphs.enumerated() {
            let paragraphStyle = ((index == 0 ? style : continuation ?? style).mutableCopy() as! NSMutableParagraphStyle)
            paragraphStyle.paragraphSpacingBefore = index == 0 ? before : 0
            paragraphStyle.paragraphSpacing = index == paragraphs.count - 1 ? after : (continuation == nil ? style.paragraphSpacing : 0)
            block.addAttributes([.paragraphStyle: paragraphStyle, .blockParagraphStyle: paragraphStyle], range: range)
        }
        let start = result.length
        result.append(block)
        return NSRange(location: start, length: block.length)
    }

    private func appendSpacer(to result: NSMutableAttributedString, height: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height; style.maximumLineHeight = height
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 4), .paragraphStyle: style, .blockParagraphStyle: style
        ]))
    }

    /// The last paragraph inside a card sets the card's bottom padding.
    private func trimTrailingSpacing(_ result: NSMutableAttributedString, from start: Int, to spacing: CGFloat) {
        guard result.length > start else { return }
        let last = (result.string as NSString).paragraphRange(for: NSRange(location: result.length - 1, length: 0))
        guard let style = (result.attribute(.blockParagraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle else { return }
        style.paragraphSpacing = spacing
        result.addAttributes([.paragraphStyle: style, .blockParagraphStyle: style], range: last)
    }

    static func color(_ kind: SyntaxHighlighter.Kind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .string: .systemRed
        case .comment: .secondaryLabelColor
        case .number: .systemIndigo
        case .type: .systemTeal
        case .key: .systemBlue
        case .variable: .systemTeal
        case .attribute: .systemOrange
        }
    }

    static func calloutStyle(_ kind: MarkdownCallout.Kind) -> (String, NSColor, String) {
        switch kind {
        case .note: ("info.circle.fill", .systemBlue, L10n.text("Заметка", "Note"))
        case .tip: ("lightbulb.fill", .systemGreen, L10n.text("Совет", "Tip"))
        case .important: ("exclamationmark.bubble.fill", .systemPurple, L10n.text("Важно", "Important"))
        case .warning: ("exclamationmark.triangle.fill", .systemOrange, L10n.text("Внимание", "Warning"))
        case .caution: ("xmark.octagon.fill", .systemRed, L10n.text("Осторожно", "Caution"))
        }
    }

    static func russianLines(_ count: Int) -> String {
        let tens = count % 100, ones = count % 10
        if (11...14).contains(tens) { return "строк" }
        if ones == 1 { return "строку" }
        if (2...4).contains(ones) { return "строки" }
        return "строк"
    }

    private static let images = NSCache<NSString, NSImage>()

    static func image(at url: URL) -> NSImage? {
        let path = url.path
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)#\(modified)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "bmp", "webp", "pdf"].contains(url.pathExtension.lowercased()),
              let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}

/// Shared state of `TranscriptMarkdown.webSources`: the matchers are built once (creating an `NSDataDetector`
/// per call dominated streaming re-renders) and the last results are kept by exact text. `webSources` is
/// `nonisolated`, so the cache is guarded by a lock.
private enum WebSourceScan {
    typealias Sources = [(url: URL, title: String?)]

    nonisolated(unsafe) static let markdownLink = try? NSRegularExpression(pattern: #"(?<!!)\[([^\]]+)\]\((https?://[^)\s]+)\)"#)
    nonisolated(unsafe) static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Most recent entry last. A streamed answer misses on every tick (its text grows), so the cache serves the
    /// re-renders of unchanged messages: toggles, the finish re-render, scrolling.
    static let capacity = 8
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [(text: String, sources: Sources)] = []

    static func cached(_ text: String) -> Sources? {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.lastIndex(where: { $0.text == text }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.sources
    }

    static func remember(_ text: String, _ sources: Sources) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.text == text }
        entries.append((text, sources))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
}
