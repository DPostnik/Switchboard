import AppKit
import ContextCore

extension NSAttributedString.Key {
    /// The caption of a compaction divider; the layout manager draws the rules on both sides of it.
    static let compactionDivider = NSAttributedString.Key("ContextDeskCompactionDivider")
}

/// A context compaction as a full-width divider at the point where it happened: a thin rule with a centered caption,
/// "Context compacted: 120k → 30k · automatic", and the exact numbers in its tooltip.
enum TranscriptCompactionDivider {
    static let gap: CGFloat = 12
    static let rule = DeskPalette.ns.muted.withAlphaComponent(0.35)
    static let activeRule = DeskPalette.ns.accent.withAlphaComponent(0.45)

    /// The caption for the item's state: a running or unconfirmed compaction keeps its status text.
    static func caption(_ item: TranscriptItem) -> String {
        guard item.phase == "completed" || item.phase == nil else { return item.text }
        return (item.compaction ?? ContextCompaction()).caption()
    }

    static func render(_ item: TranscriptItem) -> NSAttributedString {
        let active = item.phase == "inProgress"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        // The message above already ends with a blank line; the space below matches it, clear of a user bubble's overhang.
        paragraph.paragraphSpacing = 28
        // The rules need room beside the caption; a long caption wraps inside these margins instead.
        paragraph.firstLineHeadIndent = 48; paragraph.headIndent = 48; paragraph.tailIndent = -48
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph,
            .foregroundColor: active ? DeskPalette.ns.accentDeep : DeskPalette.ns.muted,
        ]
        let result = NSMutableAttributedString(string: caption(item), attributes: attributes)
        if let detail = item.compaction?.detail() { result.addAttribute(.toolTip, value: detail, range: NSRange(location: 0, length: result.length)) }
        result.addAttribute(.compactionDivider, value: active, range: NSRange(location: 0, length: result.length))
        attributes[.font] = NSFont.systemFont(ofSize: 14)
        result.append(NSAttributedString(string: "\n", attributes: attributes))
        return result
    }

    /// Rules left and right of each divider caption in `characters`, vertically centered on the caption's line.
    static func drawRules(_ manager: NSLayoutManager, storage: NSTextStorage, characters: NSRange,
                          container: NSTextContainer, origin: NSPoint) {
        storage.enumerateAttribute(.compactionDivider, in: characters) { value, range, _ in
            guard let active = value as? Bool else { return }
            var full = NSRange()
            _ = storage.attribute(.compactionDivider, at: range.location, longestEffectiveRange: &full,
                                  in: NSRange(location: 0, length: storage.length))
            let glyphs = manager.glyphRange(forCharacterRange: full, actualCharacterRange: nil)
            // A caption wrapped onto several lines (a very narrow window) stands without rules.
            var lines = 0
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in lines += 1 }
            guard lines == 1 else { return }
            let caption = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let padding = container.lineFragmentPadding
            let left = origin.x + padding, right = origin.x + container.containerSize.width - padding
            let y = (origin.y + caption.midY).rounded() - 0.5
            (active ? activeRule : rule).setFill()
            let leading = origin.x + caption.minX - gap, trailing = origin.x + caption.maxX + gap
            if leading > left { NSRect(x: left, y: y, width: leading - left, height: 1).fill() }
            if right > trailing { NSRect(x: trailing, y: y, width: right - trailing, height: 1).fill() }
        }
    }
}
