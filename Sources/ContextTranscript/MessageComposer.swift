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
    /// Runs after every change, typed or set, with the new text; the owner stores drafts through it.
    public var onChange: ((String) -> Void)?
    public init() {}
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
        }
        onChange?(text)
    }
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
    /// Read while the parent renders, so a zoom change updates the editor font.
    let fontSize = InterfaceZoom.shared.scaled(14)
    public init(state: ComposerState, focused: Binding<Bool>, focusRequest: UUID? = nil,
                onContentHeight: ((CGFloat) -> Void)? = nil, onCancel: (() -> Void)? = nil, onSubmit: @escaping () -> Void) {
        self.state = state; revision = state.revision; _focused = focused; self.focusRequest = focusRequest; self.onSubmit = onSubmit
        self.onContentHeight = onContentHeight; self.onCancel = onCancel
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // The viewport follows SwiftUI's proposal, never the document's text size.
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 0, height: 84))
    }
    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = WidthBoundTextScrollView()
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
        editor.onSubmit = onSubmit; editor.onCancel = onCancel
        editor.setAccessibilityLabel(L10n.text("Сообщение", "Message"))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        return scroll
    }
    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.onSubmit = onSubmit; editor.onCancel = onCancel
        editor.onContentHeight = onContentHeight
        if editor.font?.pointSize != fontSize { editor.font = .systemFont(ofSize: fontSize); editor.reportContentHeight() }
        if editor.string != state.text { editor.string = state.text; editor.reportContentHeight() }
        if focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            // A freshly made editor is not in a window yet; focus after SwiftUI attaches it.
            if focusRequest != nil { DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) } }
        }
    }
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageComposer
        var focusRequest: UUID?
        init(_ parent: MessageComposer) { self.parent = parent }
        public func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.state.editorChanged(editor.string) }
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
        let maxY = max(0, editor.frame.height - contentView.bounds.height)
        let origin = contentView.bounds.origin
        if origin.x != 0 || origin.y > maxY {
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
        let paths = DroppedFiles.preserving(urls, in: DroppedFiles.directory).map(\.path).joined(separator: "\n")
        insertText(paths, replacementRange: NSRange(location: index, length: 0))
        window?.makeFirstResponder(self)
        return true
    }
    public override func keyDown(with event: NSEvent) {
        // Let the input method confirm marked text before interpreting Return.
        if (event.keyCode == 36 || event.keyCode == 76) && !hasMarkedText() {
            if event.modifierFlags.contains(.shift) { insertNewlineIgnoringFieldEditor(nil) }
            else if !event.isARepeat { onSubmit?() }
            return
        }
        super.keyDown(with: event)
    }
    public override func cancelOperation(_ sender: Any?) {
        if let onCancel, !hasMarkedText() { onCancel() } else { super.cancelOperation(sender) }
    }
}
