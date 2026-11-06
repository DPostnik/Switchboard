import ContextCore
import AppKit
import SwiftUI

/// The composer's live text, kept outside the chat model so a keystroke never publishes the model.
/// `text` itself is not published: the editor is the source of typed text and needs no render for it.
/// `hasText` and `hasMessage` publish only when they flip (placeholder, send and restore buttons), and
/// `revision` publishes every write that did not come from the editor, so the editor replaces its contents.
@MainActor public final class ComposerState: ObservableObject {
    public var text: String {
        get { storage }
        set { apply(newValue, fromEditor: false) }
    }
    private var storage = ""
    /// The text is not empty.
    @Published public private(set) var hasText = false
    /// The text has more than whitespace: what can be sent.
    @Published public private(set) var hasMessage = false
    /// Counts writes that did not come from the editor.
    @Published public private(set) var revision = 0
    /// Distinct image files named in the text, in order: the bar above the composer. Publishes only when they change.
    @Published public private(set) var images: [URL] = []
    /// Runs after every change, typed or set, with the new text; the owner stores drafts through it.
    public var onChange: ((String) -> Void)?
    public init() {}

    static func images(in text: String) -> [URL] {
        var seen = Set<URL>()
        return TranscriptImagePaths.find(in: text).map(\.url.standardizedFileURL)
            .filter { TranscriptImagePaths.thumbnail($0) != nil && seen.insert($0).inserted }
    }

    /// Removes every mention of the image from the text, with one space beside each so no gap stays.
    public func removeImage(_ url: URL) {
        let target = url.standardizedFileURL
        let found = TranscriptImagePaths.find(in: storage).filter { $0.url.standardizedFileURL == target }
        guard !found.isEmpty else { return }
        let result = NSMutableString(string: storage)
        for (range, _) in found.reversed() {
            var cut = range
            let isSpace = { (index: Int) in index >= 0 && index < result.length && [0x20, 0x09].contains(result.character(at: index)) }
            if isSpace(NSMaxRange(cut)) { cut.length += 1 } else if isSpace(cut.location - 1) { cut.location -= 1; cut.length += 1 }
            result.replaceCharacters(in: cut, with: "")
        }
        text = result as String
    }
    /// The editor reports what the user typed; nothing publishes unless `hasText` or `hasMessage` flips.
    public func editorChanged(_ text: String) { apply(text, fromEditor: true) }
    private func apply(_ text: String, fromEditor: Bool) {
        if text != storage {
            storage = text
            if !fromEditor { revision &+= 1 }
            let nonEmpty = !text.isEmpty
            if hasText != nonEmpty { hasText = nonEmpty }
            let message = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasMessage != message { hasMessage = message }
            let found = Self.images(in: text)
            if images != found { images = found }
        }
        onChange?(text)
    }
}

/// Keys the composer offers a completion list while it is open.
public enum ComposerCompletionKey: Sendable { case up, down, accept, dismiss }

/// A list that completes what is typed in the composer (the `/` skill list). The editor reports every change of its
/// text or caret, and while `isActive` it offers the list's keys first, so Return accepts instead of sending.
@MainActor public protocol ComposerCompletion: AnyObject {
    var isActive: Bool { get }
    func editorChanged(_ editor: NSTextView)
    /// True when the list used the key.
    func handle(_ key: ComposerCompletionKey, in editor: NSTextView) -> Bool
}

public struct MessageComposer: NSViewRepresentable {
    let state: ComposerState
    /// Read at render time so a write from the owner makes this value differ and the editor updates.
    let revision: Int
    @Binding var focused: Bool
    /// Each new value moves keyboard focus into the editor once.
    let focusRequest: UUID?
    let onSubmit: () -> Void
    /// Esc; nil keeps the text view's default handling.
    let onCancel: (() -> Void)?
    /// Reports the text's height so the composer can grow with what is typed.
    let onContentHeight: ((CGFloat) -> Void)?
    /// Held weakly by the editor; nil leaves every key to the editor.
    let completion: (any ComposerCompletion)?
    /// Read while the parent renders, so a zoom change updates the editor font.
    let fontSize = InterfaceZoom.shared.scaled(14)
    public init(state: ComposerState, focused: Binding<Bool>, focusRequest: UUID? = nil,
                onContentHeight: ((CGFloat) -> Void)? = nil, onCancel: (() -> Void)? = nil,
                completion: (any ComposerCompletion)? = nil, onSubmit: @escaping () -> Void) {
        self.state = state; revision = state.revision; _focused = focused; self.focusRequest = focusRequest; self.onSubmit = onSubmit
        self.onContentHeight = onContentHeight; self.onCancel = onCancel; self.completion = completion
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // The viewport follows SwiftUI's proposal, never the document's text size.
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 0, height: 84))
    }
    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = WidthBoundTextScrollView(frame: .zero)
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 22))
        editor.minSize = NSSize(width: 0, height: 22)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isRichText = false; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: fontSize)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 2)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.layoutManager?.delegate = editor.images
        editor.onSubmit = onSubmit; editor.onCancel = onCancel; editor.completion = completion
        editor.setAccessibilityLabel(L10n.text("Сообщение", "Message"))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        return scroll
    }
    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.onSubmit = onSubmit; editor.onCancel = onCancel; editor.completion = completion
        editor.onContentHeight = onContentHeight
        if editor.font?.pointSize != fontSize { editor.font = .systemFont(ofSize: fontSize); editor.reportContentHeight() }
        if editor.string != state.text {
            context.coordinator.applyingOwnerText = true
            editor.string = state.text; editor.refreshImages(); editor.reportContentHeight()
            context.coordinator.applyingOwnerText = false
            // A write from the owner (send, chat switch) can end a `/` token; the list publishes, so not during this update.
            if completion != nil {
                DispatchQueue.main.async { [weak editor] in if let editor { editor.completion?.editorChanged(editor) } }
            }
        }
        if focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            // A freshly made editor is not in a window yet; focus after SwiftUI attaches it.
            if focusRequest != nil { DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) } }
        }
    }
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageComposer
        var focusRequest: UUID?
        /// The owner's text is being written into the editor during a SwiftUI update; its selection change waits.
        var applyingOwnerText = false
        init(_ parent: MessageComposer) { self.parent = parent }
        public func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            (editor as? ComposerTextView)?.refreshImages()
            (editor as? ComposerTextView)?.editing = false
            parent.state.editorChanged(editor.string)
            parent.completion?.editorChanged(editor)
        }
        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !applyingOwnerText, let editor = notification.object as? NSTextView else { return }
            parent.completion?.editorChanged(editor)
        }
        public func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                             toCharacterRange proposed: NSRange) -> NSRange {
            // During an edit the chips' ranges are those before it; they are found again once the edit ends.
            guard let editor = textView as? ComposerTextView, !editor.images.ranges.isEmpty, !editor.editing else { return proposed }
            return ComposerImages.snap(proposed, from: old, ranges: editor.images.ranges.map(\.range))
        }
        public func textView(_ textView: NSTextView, shouldChangeTextIn affected: NSRange, replacementString: String?) -> Bool {
            guard let editor = textView as? ComposerTextView, !editor.images.ranges.isEmpty, let storage = editor.textStorage,
                  let whole = ComposerImages.expanded(affected, ranges: editor.images.ranges.map(\.range), opened: editor.images.opened(in: storage))
            else { (textView as? ComposerTextView)?.editing = true; return true }
            // Deleting into a chip removes its whole path.
            editor.insertText(replacementString ?? "", replacementRange: whole)
            return false
        }
        public func textView(_ textView: NSTextView, shouldChangeTypingAttributes old: [String: Any] = [:],
                             toAttributes new: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
            // Text typed after a thumbnail is not part of its path.
            new.filter { $0.key != .composerImage && $0.key != .toolTip }
        }
        public func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
        public func textDidEndEditing(_ notification: Notification) { parent.focused = false }
    }
}

/// Autoresizing alone can preserve an oversized document after SwiftUI resizes
/// its viewport. Constrain TextKit to the actual clip width on every layout.
@MainActor public class WidthBoundTextScrollView: NSScrollView {
    /// Always overlay: a legacy scroller (system setting "Show scroll bars: Always" or a connected mouse)
    /// draws its own light track with a divider beside the chat. The scroll view reapplies the system
    /// style on every change, so the setter ignores it.
    public override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Init takes the system style without the setter.
        if window != nil { super.scrollerStyle = .overlay }
    }

    /// From a scroll gesture's start through its momentum and rubber band.
    private var boundLiveScrolling = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(boundLiveScrollStarted),
                                               name: NSScrollView.willStartLiveScrollNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(boundLiveScrollEnded),
                                               name: NSScrollView.didEndLiveScrollNotification, object: self)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func boundLiveScrollStarted() { boundLiveScrolling = true }
    @objc private func boundLiveScrollEnded() { boundLiveScrolling = false; needsLayout = true }

    public override func layout() {
        super.layout()
        // Clip bounds are in document points, which differ from the viewport under magnification.
        guard let editor = documentView as? NSTextView, contentView.bounds.width > 0 else { return }
        let width = contentView.bounds.width
        if abs(editor.frame.width - width) > 0.5 {
            editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
        }
        // A viewport that grew after an edit scrolled to the caret keeps its old offset;
        // pin it inside the document so the text does not hang below its top edge.
        // Not during a scroll gesture: past the end the rubber band stretches the viewport beyond the document, and any
        // layout pass mid-bounce (SwiftUI relaying out the window while another chat streams) snapped it to the edge for
        // a frame. The pin runs once the gesture ends.
        let maxY = max(0, editor.frame.height - contentView.bounds.height)
        let origin = contentView.bounds.origin
        if origin.x != 0 || (origin.y > maxY && !boundLiveScrolling) {
            contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, maxY)))
            reflectScrolledClipView(contentView)
        }
    }
}

public final class ComposerTextView: NSTextView {
    public var onSubmit: (() -> Void)?
    /// Esc; without it the text view keeps its default handling.
    public var onCancel: (() -> Void)?
    public var onContentHeight: ((CGFloat) -> Void)?
    /// While it is active, its navigation keys (arrows, Return, Tab, Esc without modifiers) go to it first.
    public weak var completion: (any ComposerCompletion)?
    private var reportedHeight: CGFloat = 0
    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { reportContentHeight() }
    }
    public override func didChangeText() {
        super.didChangeText()
        // An edit is not inside AppKit layout, so the viewport can grow in this same pass.
        // A deferred report drew one frame with the old viewport scrolled to the caret,
        // then a taller one: the text jumped on every new line while dictating or pasting.
        reportContentHeight(deferred: false)
    }
    /// The text's own height. The frame cannot be used: inside a scroll view it never
    /// shrinks below the viewport, so a cleared draft would keep the composer tall.
    public func reportContentHeight(deferred: Bool = true) {
        guard let onContentHeight, let manager = layoutManager, let container = textContainer else { return }
        manager.ensureLayout(for: container)
        let height = (manager.usedRect(for: container).height + textContainerInset.height * 2).rounded(.up)
        guard abs(height - reportedHeight) > 0.5 else { return }
        reportedHeight = height
        // Never publish SwiftUI state during AppKit layout.
        if deferred { DispatchQueue.main.async { onContentHeight(height) } } else { onContentHeight(height) }
    }
    /// Files keep the native result (paths at the drop point), but are read while the drop is still on
    /// and temporary ones, such as a screenshot thumbnail's, are copied before their source deletes them.
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        insertPaths(DroppedFiles.preserving(urls, in: DroppedFiles.directory), at: NSRange(location: index, length: 0))
        window?.makeFirstResponder(self)
        return true
    }
    /// Copied files paste as their paths, image data (a screenshot taken with Control) as the path of a saved PNG.
    public override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            insertPaths(DroppedFiles.preserving(urls, in: DroppedFiles.directory), at: selectedRange()); return
        }
        if pasteboard.string(forType: .string) == nil, NSImage.canInit(with: pasteboard), let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
           let file = try? DroppedFiles.savePasted(png: png, in: DroppedFiles.directory) {
            insertPaths([file], at: selectedRange()); return
        }
        super.paste(sender)
    }
    /// Paths one per line, separated from the text around them so each is found as a path.
    func insertPaths(_ urls: [URL], at range: NSRange) {
        // Images go in brackets: each stays one chip whatever is typed next to it.
        let paths = urls.filter(\.isFileURL).map { TranscriptImagePaths.isImage($0) ? TranscriptImagePaths.chipText($0.path) : $0.path }
        guard !paths.isEmpty else { return }
        let text = string as NSString
        let before = range.location > 0 ? text.character(at: range.location - 1) : 0x0A
        let after = NSMaxRange(range) < text.length ? text.character(at: NSMaxRange(range)) : 0x0A
        let isSpace = { (c: unichar) in c == 0x20 || c == 0x0A || c == 0x09 }
        insertText((isSpace(before) ? "" : " ") + paths.joined(separator: " ") + (isSpace(after) ? "" : " "), replacementRange: range)
    }

    // MARK: Image thumbnails (`ComposerImages`)

    let images = ComposerImages()
    /// Between an accepted edit and its text-change notification; the caret is not snapped to chips meanwhile.
    var editing = false
    func refreshImages() {
        guard let storage = textStorage, images.refresh(storage, layoutManager: layoutManager) else { return }
        needsDisplay = true
    }
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        images.draw(in: self, dirtyRect: dirtyRect)
    }
    /// A click selects a chip (Delete removes it), a drag moves it to another place in the text, a double-click opens it.
    public override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              let hit = images.hit(convert(event.locationInWindow, from: nil), in: self) else { return super.mouseDown(with: event) }
        if event.clickCount >= 2 { TranscriptImagePaths.open(hit.url); return }
        window?.makeFirstResponder(self)
        setSelectedRange(hit.range)
        needsDisplay = true
        let start = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                // The text view moves the selected path itself and the chip follows it.
                _ = dragSelection(with: next, offset: .zero, slideBack: true)
                return
            }
        }
    }
    public override func dragImageForSelection(with event: NSEvent, origin: NSPointPointer?) -> NSImage? {
        let selection = selectedRange()
        guard let chip = images.frames(in: self).first(where: { $0.range == selection }), let image = images.chipImage(chip.url) else {
            return super.dragImageForSelection(with: event, origin: origin)
        }
        // The origin is the image's lower-left corner; this view is flipped.
        origin?.pointee = NSPoint(x: chip.frame.minX, y: chip.frame.maxY)
        return image
    }
    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // A chip is drawn selected while the selection covers it.
        if !images.ranges.isEmpty { needsDisplay = true }
    }
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let hit = images.hit(convert(event.locationInWindow, from: nil), in: self) else { return super.menu(for: event) }
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) { menu.addItem(ComposerMenuItem(title: title, perform: action)) }
        add(L10n.text("Открыть", "Open")) { TranscriptImagePaths.open(hit.url) }
        add(L10n.text("Скопировать путь", "Copy Path")) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hit.url.path, forType: .string)
        }
        add(L10n.text("Показать в Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
        menu.addItem(.separator())
        add(L10n.text("Убрать из сообщения", "Remove from Message")) { [weak self] in
            self?.insertText("", replacementRange: hit.range)
        }
        return menu
    }
    public override func keyDown(with event: NSEvent) {
        if let completion, completion.isActive, !hasMarkedText(), let key = Self.completionKey(event),
           completion.handle(key, in: self) { return }
        // Let the input method confirm marked text before interpreting Return.
        if (event.keyCode == 36 || event.keyCode == 76) && !hasMarkedText() {
            if event.modifierFlags.contains(.shift) { insertNewlineIgnoringFieldEditor(nil) }
            else if !event.isARepeat { onSubmit?() }
            return
        }
        super.keyDown(with: event)
    }
    private static func completionKey(_ event: NSEvent) -> ComposerCompletionKey? {
        guard event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty else { return nil }
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76, 48: return .accept
        case 53: return .dismiss
        default: return nil
        }
    }
    public override func cancelOperation(_ sender: Any?) {
        if let onCancel, !hasMarkedText() { onCancel() } else { super.cancelOperation(sender) }
    }
}

@MainActor private final class ComposerMenuItem: NSMenuItem {
    private var perform: (() -> Void)?
    convenience init(title: String, perform: @escaping () -> Void) {
        self.init(title: title, action: #selector(run), keyEquivalent: "")
        self.perform = perform
        target = self
    }
    @objc private func run() { perform?() }
}
