import AppKit
import ContextCore

/// A drawing from an answer that is wider than the chat column, in its own window:
/// monospaced, unwrapped and scrollable in both directions. The text is selectable, not editable.
@MainActor final class TranscriptTextWindow: NSObject, NSWindowDelegate {
    private static var open: [TranscriptTextWindow] = []
    private var window: NSWindow?

    static func show(_ text: String, relativeTo parent: NSWindow?) {
        let controller = TranscriptTextWindow()
        open.append(controller)
        controller.present(text, relativeTo: parent)
    }

    private func present(_ text: String, relativeTo parent: NSWindow?) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = font
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        let lines = text.components(separatedBy: "\n")
        let longest = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = min(1400, max(480, longest + 60))
        let height = min(800, max(200, CGFloat(lines.count) * 16 + 60))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.text("Рисунок из ответа", "Drawing from the answer")
        window.contentView = scroll
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let parent {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - width / 2, y: frame.midY - height / 2))
        } else { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}
