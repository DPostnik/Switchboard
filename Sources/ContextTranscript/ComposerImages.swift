import AppKit
import ContextCore

extension NSAttributedString.Key {
    /// An image path in the composer drawn as a thumbnail; the value is the file URL.
    static let composerImage = NSAttributedString.Key("ContextDeskComposerImage")
}

/// Image paths in the composer show as chips ("Image 1" with a small preview) at their place in the text; the bar
/// above the composer shows the same images with the same numbers. The text keeps the path, so the draft, copy, undo
/// and the message the agent receives stay as they are: the path's first character lays out as a gap the size of the
/// chip, the others as nothing, and the text view draws the chip into the gap. The caret steps over a path as over one
/// character, deleting into it removes the whole path, and a chip can be dragged to another place in the text.
@MainActor final class ComposerImages: NSObject, @preconcurrency NSLayoutManagerDelegate {
    /// About the height of a 14 pt text line, so a line with a chip keeps the height of the others.
    static let chipHeight: CGFloat = 18
    static let previewSide: CGFloat = 12
    /// Space after a chip.
    static let padding: CGFloat = 3
    static let labelFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)

    private(set) var ranges: [(range: NSRange, url: URL)] = []
    /// Each image's number: its place among the distinct images in text order, as in the bar above the composer.
    private(set) var numbers: [URL: Int] = [:]
    var isFile: (String) -> Bool = { ChatFiles.cachedIsFile($0) }

    static func label(_ number: Int) -> String { L10n.text("Фото \(number)", "Image \(number)") }

    /// Marks the image paths of the text; true when the marks changed.
    @discardableResult func refresh(_ storage: NSTextStorage, layoutManager: NSLayoutManager?) -> Bool {
        let found = TranscriptImagePaths.find(in: storage.string, isFile: isFile).filter { TranscriptImagePaths.thumbnail($0.url) != nil }
        // Replacing the whole text (a draft switch) drops the marks even when the paths stay where they were.
        guard found.map(\.range) != ranges.map(\.range) || found.map(\.url) != ranges.map(\.url)
                || found.contains(where: { storage.attribute(.composerImage, at: $0.range.location, effectiveRange: nil) == nil })
        else { return false }
        ranges = found
        numbers = [:]
        for (_, url) in found where numbers[url.standardizedFileURL] == nil { numbers[url.standardizedFileURL] = numbers.count + 1 }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.composerImage, range: all)
        storage.removeAttribute(.toolTip, range: all)
        for (range, url) in found {
            storage.addAttributes([.composerImage: url, .toolTip: url.path + "\n" + L10n.text(
                "Двойной клик - открыть, перетащите, чтобы переместить, Backspace после чипа - раскрыть путь; агент получит путь к файлу на этом месте",
                "Double-click to open, drag to move, Backspace after the chip shows the path; the agent gets the file path at this place")], range: range)
        }
        storage.endEditing()
        layoutManager?.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
        layoutManager?.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        return true
    }

    /// Chips written in brackets: deleting a bracket opens them into text.
    func opened(in storage: NSTextStorage) -> [NSRange] {
        let string = storage.string as NSString
        return ranges.map(\.range).filter { $0.length > 1 && NSMaxRange($0) <= string.length && string.character(at: $0.location) == 0x5B }
    }

    func number(for url: URL) -> Int { numbers[url.standardizedFileURL] ?? 1 }

    /// The chip's size: preview, gap, label and side insets.
    func size(for url: URL) -> NSSize? {
        let label = (Self.label(number(for: url)) as NSString).size(withAttributes: [.font: Self.labelFont])
        return NSSize(width: (4 + Self.previewSide + 4 + label.width + 6).rounded(.up), height: Self.chipHeight)
    }

    // MARK: Editing

    /// The caret never rests inside a path: it moves to the side it travels to; a selection grows to whole paths.
    nonisolated static func snap(_ proposed: NSRange, from old: NSRange, ranges: [NSRange]) -> NSRange {
        var result = proposed
        for range in ranges {
            let inside = { (index: Int) in index > range.location && index < NSMaxRange(range) }
            if result.length == 0 {
                if inside(result.location) { result.location = proposed.location < old.location ? range.location : NSMaxRange(range) }
                continue
            }
            if inside(result.location) { result.length += result.location - range.location; result.location = range.location }
            if inside(NSMaxRange(result)) { result.length = NSMaxRange(range) - result.location }
        }
        return result
    }

    /// An edit that cuts into a path takes the whole path; nil when it cuts into none. Deleting only a bracket of a
    /// bracketed path (`opened`) is left alone: it turns the chip back into its text.
    nonisolated static func expanded(_ affected: NSRange, ranges: [NSRange], opened: [NSRange] = []) -> NSRange? {
        guard affected.length > 0 else { return nil }
        if affected.length == 1, opened.contains(where: { affected.location == $0.location || affected.location == NSMaxRange($0) - 1 }) {
            return nil
        }
        var result = affected
        for range in ranges where NSIntersectionRange(range, result).length > 0 && NSUnionRange(range, result) != result {
            result = NSUnionRange(range, result)
        }
        return result == affected ? nil : result
    }

    // MARK: Layout

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !ranges.isEmpty, let storage = layoutManager.textStorage else { return 0 }
        var changed: [NSLayoutManager.GlyphProperty]?
        for offset in 0..<glyphRange.length {
            let index = characterIndexes[offset]
            guard index < storage.length else { continue }
            var effective = NSRange()
            guard storage.attribute(.composerImage, at: index, effectiveRange: &effective) != nil else { continue }
            if changed == nil { changed = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length)) }
            changed?[offset] = index == effective.location ? .controlCharacter : .null
        }
        guard let changed else { return 0 }
        changed.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = layoutManager.textStorage, charIndex < storage.length,
              storage.attribute(.composerImage, at: charIndex, effectiveRange: nil) != nil else { return action }
        return .whitespace
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let url = layoutManager.textStorage?.attribute(.composerImage, at: charIndex, effectiveRange: nil) as? URL,
              let size = size(for: url) else { return .zero }
        return NSRect(x: glyphPosition.x, y: 0, width: size.width + Self.padding, height: size.height)
    }

    /// A line lower than a chip grows to hold it, by the same amount above and below its text.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard !ranges.isEmpty else { return false }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard let height = ranges.filter({ NSLocationInRange($0.range.location, characters) }).compactMap({ size(for: $0.url)?.height }).max()
        else { return false }
        let extra = (height - lineFragmentRect.pointee.height).rounded(.up)
        guard extra > 0 else { return false }
        lineFragmentRect.pointee.size.height += extra
        lineFragmentUsedRect.pointee.size.height += extra
        baselineOffset.pointee += extra / 2
        return true
    }

    // MARK: Drawing and hits

    /// Thumbnail frames in the text view's coordinates.
    func frames(in view: NSTextView) -> [(frame: NSRect, range: NSRange, url: URL)] {
        guard !ranges.isEmpty, let manager = view.layoutManager, let storage = view.textStorage else { return [] }
        let origin = view.textContainerOrigin
        return ranges.compactMap { range, url in
            guard NSMaxRange(range) <= storage.length, let size = size(for: url) else { return nil }
            let glyph = manager.glyphIndexForCharacter(at: range.location)
            guard manager.isValidGlyphIndex(glyph) else { return nil }
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = manager.location(forGlyphAt: glyph)
            // Centered on the text's middle (half the capital height above the baseline), not on the line box.
            let middle = line.minY + location.y - (view.font?.capHeight ?? 10) / 2
            let frame = NSRect(x: origin.x + line.minX + location.x, y: origin.y + (middle - size.height / 2).rounded(),
                               width: size.width, height: size.height)
            return (frame, range, url)
        }
    }

    func draw(in view: NSTextView, dirtyRect: NSRect) {
        let selection = view.selectedRange()
        for (frame, range, url) in frames(in: view) where frame.intersects(dirtyRect) {
            let selected = selection.length > 0 && NSIntersectionRange(selection, range).length == range.length
            drawChip(url, in: frame, selected: selected)
        }
    }

    /// A rounded chip: the image's preview cropped to a square, then its label.
    func drawChip(_ url: URL, in frame: NSRect, selected: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let chip = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (selected ? DeskPalette.ns.accent.withAlphaComponent(0.22) : DeskPalette.ns.accent.withAlphaComponent(0.1)).setFill()
        chip.fill()
        (selected ? DeskPalette.ns.accent : DeskPalette.ns.accent.withAlphaComponent(0.35)).setStroke()
        chip.lineWidth = selected ? 1.5 : 1
        chip.stroke()
        let preview = NSRect(x: frame.minX + 4, y: frame.midY - Self.previewSide / 2, width: Self.previewSide, height: Self.previewSide)
        if let image = TranscriptImagePaths.thumbnail(url) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: preview, xRadius: 3, yRadius: 3).addClip()
            // Aspect fill: the middle square of the image.
            let side = min(image.size.width, image.size.height)
            let source = NSRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
            image.draw(in: preview, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        }
        let label = Self.label(number(for: url)) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: DeskPalette.ns.accentDeep]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: preview.maxX + 4, y: frame.midY - size.height / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The chip alone, as the image dragged when it moves.
    func chipImage(_ url: URL) -> NSImage? {
        guard let size = size(for: url) else { return nil }
        return NSImage(size: size, flipped: true) { [weak self] rect in
            MainActor.assumeIsolated { self?.drawChip(url, in: rect, selected: true) }
            return true
        }
    }

    func hit(_ point: NSPoint, in view: NSTextView) -> (range: NSRange, url: URL)? {
        frames(in: view).first { $0.frame.contains(point) }.map { ($0.range, $0.url) }
    }
}
