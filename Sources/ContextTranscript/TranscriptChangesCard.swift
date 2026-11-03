import AppKit
import ContextCore

extension NSAttributedString.Key {
    /// The bordered card under a finished answer listing the turn's changed files; value is the row item's id.
    static let changesCard = NSAttributedString.Key("ContextDeskChangesCard")
    /// Start of a file row inside the changes card (true); a rule is drawn above every row but the first.
    static let changesRow = NSAttributedString.Key("ContextDeskChangesRow")
}

/// The changed files of a finished turn as a card under its answer: one row per file with its icon, name and line
/// counts, created files with their type badge and size. A click opens the turn's changes at that file.
@MainActor enum TranscriptChangesCard {
    nonisolated static let itemKind = "turnChanges"
    /// Rows shown before "N more files".
    static let rowLimit = 6
    nonisolated static let linkPrefix = "contextdesk-changes:"

    /// The synthetic row placed after a finished turn's answer; it carries the turn's timing (and so its changes).
    nonisolated static func item(for timing: ResponseTiming, sourceID: String) -> TranscriptItem? {
        guard let changes = timing.changes, changes.files > 0 else { return nil }
        var item = TranscriptItem(id: sourceID + ":changes", kind: itemKind, text: "", timing: timing)
        item.showsAuthor = false; item.showsCopyControl = false
        return item
    }

    nonisolated static func link(_ itemID: String, file: String?) -> String {
        linkPrefix + itemID + (file.map { "\t" + $0 } ?? "")
    }

    /// Item id and optional file of a card link.
    nonisolated static func parse(_ value: String) -> (itemID: String, file: String?)? {
        guard value.hasPrefix(linkPrefix) else { return nil }
        let parts = value.dropFirst(linkPrefix.count).split(separator: "\t", maxSplits: 1).map(String.init)
        guard let id = parts.first else { return nil }
        return (id, parts.count > 1 ? parts[1] : nil)
    }

    /// A binary file that still exists (PDF, image) opens in the preview pane: its diff has nothing to show.
    nonisolated static func previewURL(_ changes: TurnChanges, file: String?) -> URL? {
        guard let file, let entry = changes.list?.first(where: { $0.path == file }),
              entry.added == nil, entry.removed == nil, entry.status != "deleted" else { return nil }
        return URL(fileURLWithPath: changes.repository).appendingPathComponent(file)
    }

    static func render(_ item: TranscriptItem, width: CGFloat, padding: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard let changes = item.timing?.changes else { return result }
        let paragraph = style(width: width, padding: padding)
        let body = NSFont.systemFont(ofSize: 13)
        let small = NSFont.systemFont(ofSize: 11.5)
        let counts = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        func row(_ link: String, _ build: (NSMutableAttributedString) -> Void) {
            let line = NSMutableAttributedString()
            build(line)
            line.append(NSAttributedString(string: "\n"))
            let whole = NSRange(location: 0, length: line.length)
            // Row height is added above the text; the offset centres it between the rules.
            line.addAttributes([.link: link, .changesCard: item.id, .paragraphStyle: paragraph, .baselineOffset: 8], range: whole)
            line.addAttribute(.changesRow, value: true, range: NSRange(location: 0, length: 1))
            result.append(line)
        }
        func numbers(_ added: Int?, _ removed: Int?, into line: NSMutableAttributedString) {
            if let added { line.append(NSAttributedString(string: "+\(added)", attributes: [.font: counts, .foregroundColor: DeskPalette.ns.accent])) }
            if let removed {
                line.append(NSAttributedString(string: (added == nil ? "" : " ") + "−\(removed)",
                                               attributes: [.font: counts, .foregroundColor: DeskPalette.ns.problem]))
            }
        }
        guard let list = changes.list, !list.isEmpty else {
            // Turns recorded before the file list existed: one summary row.
            row(link(item.id, file: nil)) { line in
                line.append(NSAttributedString(attachment: symbol("doc.on.doc")))
                line.append(NSAttributedString(string: "\u{2009} " + L10n.text("Изменено файлов: \(changes.files)", "\(changes.files) \(changes.files == 1 ? "file" : "files") changed"),
                                               attributes: [.font: body, .foregroundColor: DeskPalette.ns.ink]))
                line.append(NSAttributedString(string: "\t", attributes: [.font: body]))
                numbers(changes.added, changes.removed, into: line)
            }
            result.append(gap())
            return result
        }
        for file in list.prefix(list.count > rowLimit + 1 ? rowLimit : rowLimit + 1) {
            let url = URL(fileURLWithPath: changes.repository).appendingPathComponent(file.path)
            let created = file.status == "added" || file.status == "copied"
            let deleted = file.status == "deleted"
            row(link(item.id, file: file.path)) { line in
                line.append(NSAttributedString(attachment: created ? badge(url.pathExtension) : icon(url)))
                var name: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: deleted ? DeskPalette.ns.muted : DeskPalette.ns.ink,
                                                           .toolTip: file.path]
                line.append(NSAttributedString(string: "\u{2009} ", attributes: name))
                if deleted { name[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                line.append(NSAttributedString(string: url.lastPathComponent, attributes: name))
                let folder = (file.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    line.append(NSAttributedString(string: "  " + middleTruncated(folder, limit: 42),
                                                   attributes: [.font: small, .foregroundColor: DeskPalette.ns.muted, .toolTip: file.path]))
                }
                line.append(NSAttributedString(string: "\t", attributes: [.font: body]))
                if created, let size = file.size {
                    line.append(NSAttributedString(string: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + "  ",
                                                   attributes: [.font: small, .foregroundColor: DeskPalette.ns.muted]))
                }
                if file.added == nil && file.removed == nil {
                    line.append(NSAttributedString(string: L10n.text("двоичный", "binary"), attributes: [.font: small, .foregroundColor: DeskPalette.ns.muted]))
                } else {
                    numbers(deleted ? nil : file.added ?? 0, created ? nil : file.removed ?? 0, into: line)
                }
            }
        }
        let shown = min(list.count, list.count > rowLimit + 1 ? rowLimit : rowLimit + 1)
        if changes.files > shown {
            row(link(item.id, file: nil)) { line in
                let more = changes.files - shown
                line.append(NSAttributedString(string: L10n.text("Ещё файлов: \(more)", "\(more) more \(more == 1 ? "file" : "files")"),
                                               attributes: [.font: small, .foregroundColor: DeskPalette.ns.accentDeep]))
                line.append(NSAttributedString(string: "\t", attributes: [.font: small]))
                line.append(NSAttributedString(string: L10n.text("всего ", "total ") , attributes: [.font: small, .foregroundColor: DeskPalette.ns.muted]))
                numbers(changes.added, changes.removed, into: line)
            }
        }
        if changes.otherChats == true {
            result.append(NSAttributedString(string: L10n.text("Во время хода в этой папке работал другой чат: его правки могут быть здесь.\n",
                                                               "Another chat worked in this folder during the turn: its edits may be included.\n"),
                                             attributes: [.font: small, .foregroundColor: DeskPalette.ns.attentionInk, .paragraphStyle: note(width: width, padding: padding)]))
        }
        result.append(gap())
        return result
    }

    /// The blank line after the card; it is taller than the next user bubble's overhang, so the bubble does not touch the card.
    private static func gap() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 28; style.maximumLineHeight = 28
        return NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 8), .paragraphStyle: style])
    }

    /// Rows are inset inside the card; the counts sit on a right tab at the card's inner edge.
    static func style(width: CGFloat, padding: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 14; style.headIndent = 14; style.tailIndent = -14
        style.minimumLineHeight = 34; style.maximumLineHeight = 34
        style.lineBreakMode = .byTruncatingMiddle
        let right = max(120, width - 2 * padding - 14)
        style.tabStops = [NSTextTab(textAlignment: .right, location: right)]
        style.defaultTabInterval = 0
        return style
    }

    private static func note(width: CGFloat, padding: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 4; style.headIndent = 4; style.paragraphSpacingBefore = 6
        return style
    }

    /// Re-sets the right tab after the column width changed.
    static func restyle(_ text: NSMutableAttributedString, range: NSRange, width: CGFloat, padding: CGFloat) {
        let paragraph = style(width: width, padding: padding)
        text.enumerateAttribute(.changesCard, in: range) { value, cardRange, _ in
            guard value != nil else { return }
            text.addAttribute(.paragraphStyle, value: paragraph, range: cardRange)
        }
    }

    private static func middleTruncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let half = (limit - 1) / 2
        return String(text.prefix(half)) + "…" + String(text.suffix(half))
    }

    private static func icon(_ url: URL) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = TranscriptLinks.fileIcon(url)
        attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
        return attachment
    }

    private static func symbol(_ name: String) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(paletteColors: [DeskPalette.ns.muted])))
        attachment.bounds = NSRect(x: 0, y: -2, width: 15, height: 15)
        return attachment
    }

    /// A created file's type as a small rounded badge ("MD", "SWIFT"), as attachments show it.
    private static var badges: [String: NSImage] = [:]
    private static func badge(_ pathExtension: String) -> NSTextAttachment {
        let label = String((pathExtension.isEmpty ? "FILE" : pathExtension.uppercased()).prefix(4))
        let image: NSImage
        if let cached = badges[label] { image = cached } else {
            let font = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
            let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: DeskPalette.ns.inkSoft])
            let size = NSSize(width: max(22, ceil(text.size().width) + 10), height: 16)
            image = NSImage(size: size, flipped: false) { rect in
                let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
                DeskPalette.ns.canvas.setFill(); shape.fill()
                DeskPalette.ns.border.setStroke(); shape.lineWidth = 1; shape.stroke()
                let textSize = text.size()
                text.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2 + 0.5))
                return true
            }
            badges[label] = image
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -3.5, width: image.size.width, height: image.size.height)
        return attachment
    }
}
