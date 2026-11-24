import ContextCore
import ContextTranscript
import AppKit
import SwiftUI

/// Applies the interface zoom to text that has no explicit style and to standard controls.
struct InterfaceZoomed: ViewModifier {
    func body(content: Content) -> some View {
        let scale = InterfaceZoom.shared.scale
        content.font(.ui(.body)).controlSize(scale >= 1.25 ? .large : .regular)
    }
}

/// View menu commands, as in Safari and Xcode: ⌘= zooms in, ⌘− zooms out, ⌘0 returns to actual size.
struct InterfaceZoomMenu: View {
    private let zoom = InterfaceZoom.shared
    var body: some View {
        Button(L10n.text("Увеличить", "Zoom In")) { zoom.zoomIn() }
            .keyboardShortcut("=", modifiers: .command).disabled(!zoom.canZoomIn)
        Button(L10n.text("Уменьшить", "Zoom Out")) { zoom.zoomOut() }
            .keyboardShortcut("-", modifiers: .command).disabled(!zoom.canZoomOut)
        Button(L10n.text("Фактический размер (\(zoom.percent)%)", "Actual Size (\(zoom.percent)%)")) { zoom.reset() }
            .keyboardShortcut("0", modifiers: .command).disabled(zoom.isActualSize)
    }
}

/// Settings row for the same zoom; changes apply immediately.
struct InterfaceZoomSettings: View {
    private let zoom = InterfaceZoom.shared
    var body: some View {
        Section(L10n.text("Масштаб интерфейса", "Interface scale")) {
            Picker(L10n.text("Размер текста и интерфейса", "Text and interface size"),
                   selection: Binding(get: { zoom.scale }, set: { zoom.set($0) })) {
                ForEach(InterfaceZoom.steps, id: \.self) { step in
                    Text(step == 1 ? L10n.text("100% (стандарт)", "100% (default)") : "\(Int((step * 100).rounded()))%").tag(step)
                }
            }
            .pointingHandCursor()
            Text(L10n.text("Для 4K-монитора 24–27″ обычно подходит 125–160%. Горячие клавиши: ⌘= увеличить, ⌘− уменьшить, ⌘0 — 100%.",
                           "For a 24–27″ 4K monitor, 125–160% usually works well. Shortcuts: ⌘= zoom in, ⌘− zoom out, ⌘0 back to 100%."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
        }
    }
}

/// The system toolbar title keeps its own font size, so a zoomed window shows its own title instead.
/// The navigation title stays set for the Window menu and Mission Control. At 100% nothing changes.
struct ZoomedWindowTitle: ViewModifier {
    let title: String
    let subtitle: String
    func body(content: Content) -> some View {
        if InterfaceZoom.shared.isActualSize {
            content
        } else if #available(macOS 26, *) {
            content.toolbar(removing: .title).toolbar {
                ToolbarItem(placement: .navigation) { label }.sharedBackgroundVisibility(.hidden)
                // The system title stretched across the toolbar; keep the actions at the trailing edge.
                ToolbarSpacer(.flexible)
            }
        } else if #available(macOS 15, *) {
            content.toolbar(removing: .title).toolbar { ToolbarItem(placement: .navigation) { label } }
        } else {
            content
        }
    }
    private var label: some View {
        // The toolbar height is fixed, so the title stops growing at 140%.
        let scale = min(InterfaceZoom.shared.scale, 1.4)
        return VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: (13 * scale).rounded(), weight: .bold)).lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: (11 * scale).rounded())).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Apply the fixed width to the native split item as well, including after restoring a window or changing zoom.
struct FixedSidebarWidth: NSViewRepresentable {
    let width: CGFloat
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let width = width
        // The view joins the split view only after SwiftUI attaches it to the window.
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let current = ancestor, !(current is NSSplitView) { ancestor = current.superview }
            guard let split = ancestor as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
                  let item = controller.splitViewItems.first, !item.isCollapsed else { return }
            guard item.minimumThickness != width || item.maximumThickness != width else { return }
            // Widen the allowed range first when the new width is above the current maximum.
            if width > item.maximumThickness { item.maximumThickness = width }
            item.minimumThickness = width
            item.maximumThickness = width
            split.setPosition(width, ofDividerAt: 0)
        }
    }
}
