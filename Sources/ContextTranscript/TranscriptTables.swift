import AppKit
import ContextCore

extension NSAttributedString.Key {
    static let transcriptTableStyle = NSAttributedString.Key("ContextDeskTableStyle")
}

/// Native text blocks keep cells selectable and links interactive in the same
/// text view as prose. No HTML parsing, attachment screenshots or web view.
@MainActor enum TranscriptTables {
    static func render(_ model: MarkdownTable, attributes: [NSAttributedString.Key: Any],
                       options: TranscriptLinks.Options = TranscriptLinks.Options()) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let table = NSTextTable()
        table.numberOfColumns = model.alignments.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        let alignments = model.displayAlignments
        // Wide tables: smaller type and short URLs keep columns readable in narrow panes.
        let wide = model.alignments.count >= 5
        var options = options
        if wide { options.urlDisplayLimit = 24 }
        let size: CGFloat = wide ? 12 : 13.5
        for (rowIndex, row) in model.rows.enumerated() {
            for (column, value) in row.enumerated() {
                let cell = TranscriptTableCell(table: table, startingRow: rowIndex, rowSpan: 1,
                                               startingColumn: column, columnSpan: 1)
                cell.rowCount = model.rows.count
                cell.setContentWidth(100 / CGFloat(table.numberOfColumns), type: .percentageValueType)
                cell.verticalAlignment = .topAlignment
                cell.setWidth(8, type: .absoluteValueType, for: .padding)
                cell.setWidth(5, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(5, type: .absoluteValueType, for: .padding, edge: .maxY)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                style.lineSpacing = 3
                style.lineBreakMode = .byWordWrapping
                switch alignments[column] {
                case .left: style.alignment = .left
                case .center: style.alignment = .center
                case .right: style.alignment = .right
                }
                var cellAttributes = attributes
                cellAttributes[.font] = NSFont.systemFont(ofSize: rowIndex == 0 ? size - 0.5 : size, weight: rowIndex == 0 ? .semibold : .regular)
                if alignments[column] == .right, rowIndex > 0 {
                    cellAttributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
                }
                cellAttributes[.paragraphStyle] = style
                cellAttributes[.transcriptTableStyle] = style
                result.append(TranscriptLinks.render(value, attributes: cellAttributes, options: options))
                result.append(NSAttributedString(string: "\n", attributes: cellAttributes))
            }
        }
        return result
    }

    static func restoreStyles(in text: NSMutableAttributedString, range: NSRange) {
        text.enumerateAttribute(.transcriptTableStyle, in: range) { value, cellRange, _ in
            guard let style = value as? NSParagraphStyle else { return }
            text.addAttribute(.paragraphStyle, value: style, range: cellRange)
        }
    }
}

/// Draws its part of the table frame itself: a rounded 1 pt outer border, row separators and the header fill.
/// Columns are separated by padding only. Interior sides are pushed far outside the cell before rounding,
/// so only the table's own corners come out rounded.
final class TranscriptTableCell: NSTextTableBlock {
    var rowCount = 0
    static let radius: CGFloat = 10

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        (copy as? TranscriptTableCell)?.rowCount = rowCount
        return copy
    }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange,
                                 layoutManager: NSLayoutManager) {
        let top = startingRow == 0, bottom = startingRow + rowSpan >= rowCount
        let left = startingColumn == 0, right = startingColumn + columnSpan >= table.numberOfColumns
        let far: CGFloat = 10_000
        var outer = frameRect
        if !left { outer.origin.x -= far; outer.size.width += far }
        if !right { outer.size.width += far }
        // Text views are flipped: the first row is at the smallest y.
        let flipped = controlView?.isFlipped ?? true
        if !(flipped ? top : bottom) { outer.origin.y -= far; outer.size.height += far }
        if !(flipped ? bottom : top) { outer.size.height += far }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frameRect).addClip()
        if top {
            DeskPalette.ns.subtle.setFill()
            NSBezierPath(roundedRect: outer, xRadius: Self.radius, yRadius: Self.radius).fill()
        }
        DeskPalette.ns.border.set()
        let frame = NSBezierPath(roundedRect: outer.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius - 0.5, yRadius: Self.radius - 0.5)
        frame.lineWidth = 1
        frame.stroke()
        if !bottom {
            NSRect(x: frameRect.minX, y: flipped ? frameRect.maxY - 1 : frameRect.minY, width: frameRect.width, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
