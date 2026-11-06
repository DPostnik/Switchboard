import AppKit
import ContextCore

extension NSAttributedString.Key {
    /// An image path in the composer drawn as a thumbnail; the value is the file URL.
    static let composerImage = NSAttributedString.Key("ContextDeskComposerImage")
}

/// Image paths in the composer show as thumbnails at their place in the text. The text keeps the path, so the draft,
/// copy, undo and the message the agent receives stay as they are: the path's first character lays out as a gap the
/// size of the thumbnail, the others as nothing, and the text view draws the image into the gap. The caret steps over
/// a path as over one character, and deleting into it removes the whole path.
@MainActor final class ComposerImages: NSObject, @preconcurrency NSLayoutManagerDelegate {
    static let maxSize = NSSize(width: 120, height: 72)
    /// Space above and below a thumbnail inside its line, and after it.
    static let padding: CGFloat = 3

    private(set) var ranges: [(range: NSRange, url: URL)] = []
    private var sizes: [URL: NSSize] = [:]
    var isFile: (String) -> Bool = { ChatFiles.cachedIsFile($0) }

    /// Marks the image paths of the text; true when the marks changed.
    @discardableResult func refresh(_ storage: NSTextStorage, layoutManager: NSLayoutManager?) -> Bool {
        let found = TranscriptImagePaths.find(in: storage.string, isFile: isFile).filter { size(for: $0.url) != nil }
        // Replacing the whole text (a draft switch) drops the marks even when the paths stay where they were.
        guard found.map(\.range) != ranges.map(\.range) || found.map(\.url) != ranges.map(\.url)
                || found.contains(where: { storage.attribute(.composerImage, at: $0.range.location, effectiveRange: nil) == nil })
        else { return false }
        ranges = found
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.composerImage, range: all)
        storage.removeAttribute(.toolTip, range: all)
        for (range, url) in found {
            storage.addAttributes([.composerImage: url, .toolTip: url.path + "\n" + L10n.text(
                "Нажмите, чтобы открыть; агент получит путь к файлу на этом месте",
                "Click to open; the agent gets the file path at this place")], range: range)
        }
        storage.endEditing()
        layoutManager?.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
        layoutManager?.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        return true
    }

    func size(for url: URL) -> NSSize? {
        if let known = sizes[url] { return known }
        guard let image = TranscriptImagePaths.thumbnail(url) else { return nil }
        let scale = min(1, Self.maxSize.width / max(1, image.size.width), Self.maxSize.height / max(1, image.size.height))
        let size = NSSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
        if sizes.count > 256 { sizes.removeAll() }
        sizes[url] = size
        return size
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

    /// An edit that cuts into a path takes the whole path; nil when it cuts into none.
    nonisolated static func expanded(_ affected: NSRange, ranges: [NSRange]) -> NSRange? {
        guard affected.length > 0 else { return nil }
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

    /// A line with a thumbnail grows to hold it; its text sits on the thumbnail's bottom edge.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard !ranges.isEmpty else { return false }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard let height = ranges.filter({ NSLocationInRange($0.range.location, characters) }).compactMap({ size(for: $0.url)?.height }).max()
        else { return false }
        let extra = height + 2 * Self.padding - lineFragmentRect.pointee.height
        guard extra > 0 else { return false }
        lineFragmentRect.pointee.size.height += extra
        lineFragmentUsedRect.pointee.size.height += extra
        baselineOffset.pointee += extra
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
            let frame = NSRect(x: origin.x + line.minX + location.x, y: origin.y + line.minY + Self.padding, width: size.width, height: size.height)
            return (frame, range, url)
        }
    }

    func draw(in view: NSTextView, dirtyRect: NSRect) {
        for (frame, _, url) in frames(in: view) where frame.intersects(dirtyRect) {
            guard let image = TranscriptImagePaths.thumbnail(url) else { continue }
            NSGraphicsContext.saveGraphicsState()
            let path = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
            path.addClip()
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    func hit(_ point: NSPoint, in view: NSTextView) -> (range: NSRange, url: URL)? {
        frames(in: view).first { $0.frame.contains(point) }.map { ($0.range, $0.url) }
    }
}
