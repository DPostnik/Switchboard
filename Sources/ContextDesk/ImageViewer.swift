import AgentContract
import AppKit
import ContextCore
import ContextTranscript
import SwiftUI

/// Images open in a viewer over the window instead of the side preview: fitted to the window, zoomed with a pinch,
/// a double-click or ⌘+ / ⌘−, ← → step through the chat's images, Esc or a click beside the image closes it.
@MainActor final class ImageViewerState: ObservableObject {
    static let shared = ImageViewerState()
    @Published private(set) var images: [URL] = []
    @Published private(set) var index = 0
    var current: URL? { images.indices.contains(index) ? images[index] : nil }

    /// Shows `url`; `gallery` (the chat's images in order) lets the arrows step through the others.
    func show(_ url: URL, gallery: [URL] = []) {
        var list = gallery.map(\.standardizedFileURL)
        let target = url.standardizedFileURL
        if !list.contains(target) { list = [target] }
        images = list
        index = list.firstIndex(of: target) ?? 0
    }
    func step(_ delta: Int) {
        guard images.count > 1 else { return }
        index = (index + delta + images.count) % images.count
    }
    func close() { images = []; index = 0 }

    /// Image files pasted into the user's messages of a chat, in order, each once.
    static func gallery(_ items: [TranscriptItem]) -> [URL] {
        var seen = Set<URL>()
        return items.filter { $0.kind == "user" }
            .flatMap { TranscriptImagePaths.find(in: $0.text).map(\.url.standardizedFileURL) }
            .filter { seen.insert($0).inserted }
    }
}

struct ImageViewerOverlay: View {
    @ObservedObject var state: ImageViewerState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let url = state.current {
                Color.black.opacity(0.78).ignoresSafeArea()
                    .onTapGesture { state.close() }
                VStack(spacing: 0) {
                    toolbar(url)
                    ZoomableImage(url: url, onClose: { state.close() }, onStep: { state.step($0) })
                        .id(url)
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.current)
    }

    private func toolbar(_ url: URL) -> some View {
        HStack(spacing: 14) {
            Text(url.lastPathComponent).font(.ui(.headline)).lineLimit(1).truncationMode(.middle)
            if state.images.count > 1 {
                Text("\(state.index + 1) / \(state.images.count)").font(.ui(.callout)).monospacedDigit().opacity(0.7)
            }
            Spacer(minLength: 12)
            if state.images.count > 1 {
                button("chevron.left", L10n.text("Предыдущее (←)", "Previous (←)")) { state.step(-1) }
                button("chevron.right", L10n.text("Следующее (→)", "Next (→)")) { state.step(1) }
            }
            button("doc.on.doc", L10n.text("Скопировать путь", "Copy path")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)
            }
            button("folder", L10n.text("Показать в Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            button("arrow.up.forward.app", L10n.text("Открыть в программе по умолчанию", "Open in default app")) { NSWorkspace.shared.open(url) }
            button("xmark", L10n.text("Закрыть (Esc)", "Close (Esc)")) { state.close() }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 28, height: 28) }
            .buttonStyle(.plain).contentShape(Rectangle()).help(help).accessibilityLabel(help)
    }
}

/// The image in a magnifying scroll view; it takes keyboard focus while shown.
private struct ZoomableImage: NSViewRepresentable {
    let url: URL
    let onClose: () -> Void
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> ImageZoomView {
        let view = ImageZoomView(image: NSImage(contentsOf: url))
        view.onClose = onClose; view.onStep = onStep
        return view
    }
    func updateNSView(_ view: ImageZoomView, context: Context) {
        view.onClose = onClose; view.onStep = onStep
    }
}

private final class ImageZoomView: NSScrollView {
    var onClose: (() -> Void)?
    var onStep: ((Int) -> Void)?
    /// Follows the window's size until the user zooms.
    private var fitted = true
    private let imageSize: NSSize

    init(image: NSImage?) {
        // An unreadable file leaves room for the message.
        imageSize = image.flatMap { $0.size.width > 0 && $0.size.height > 0 ? $0.size : nil } ?? NSSize(width: 320, height: 40)
        super.init(frame: .zero)
        let clip = CenteringClipView()
        clip.drawsBackground = false
        clip.onBackgroundClick = { [weak self] in self?.onClose?() }
        contentView = clip
        let canvas = ImageCanvas(image: image)
        canvas.frame = NSRect(origin: .zero, size: imageSize)
        canvas.onDoubleClick = { [weak self] point in self?.toggleZoom(at: point) }
        documentView = canvas
        drawsBackground = false
        hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 0.02; maxMagnification = 16
        setAccessibilityLabel(L10n.text("Изображение", "Image"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in if let self { self.window?.makeFirstResponder(self) } }
    }

    private var fitMagnification: CGFloat {
        let area = contentView.frame.size
        guard area.width > 0, area.height > 0 else { return 1 }
        return max(minMagnification, min(1, area.width / imageSize.width, area.height / imageSize.height))
    }
    override func layout() {
        super.layout()
        if fitted, abs(magnification - fitMagnification) > 0.0005 { magnification = fitMagnification }
    }
    private func fit() { fitted = true; magnification = fitMagnification }
    private func zoom(by factor: CGFloat) {
        fitted = false
        let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(min(maxMagnification, max(minMagnification, magnification * factor)), centeredAt: center)
    }
    /// Fitted (or smaller than actual size) → actual size at the clicked point; otherwise back to fitted.
    private func toggleZoom(at point: NSPoint) {
        if fitted && fitMagnification < 0.999 { fitted = false; setMagnification(1, centeredAt: point) } else { fit() }
    }
    override func magnify(with event: NSEvent) { fitted = false; super.magnify(with: event) }
    override func smartMagnify(with event: NSEvent) {
        toggleZoom(at: documentView?.convert(event.locationInWindow, from: nil) ?? .zero)
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch (event.keyCode, event.charactersIgnoringModifiers ?? "") {
        case (53, _): onClose?()
        case (123, _): onStep?(-1)
        case (124, _): onStep?(1)
        case (_, "=") where command, (_, "+") where command: zoom(by: 1.25)
        case (_, "-") where command: zoom(by: 0.8)
        case (_, "0") where command: fit()
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { onClose?() }
}

/// Keeps a smaller image in the middle of the viewer; a click beside the image closes it.
private final class CenteringClipView: NSClipView {
    var onBackgroundClick: (() -> Void)?
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, let document = documentView,
              !document.frame.contains(convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        onBackgroundClick?()
    }
}

private final class ImageCanvas: NSView {
    let image: NSImage?
    var onDoubleClick: ((NSPoint) -> Void)?
    init(image: NSImage?) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else {
            let text = L10n.text("Не удалось открыть изображение", "Could not open the image") as NSString
            text.draw(at: NSPoint(x: 8, y: 8), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13)])
            return
        }
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(convert(event.locationInWindow, from: nil)) } else { super.mouseDown(with: event) }
    }
}
