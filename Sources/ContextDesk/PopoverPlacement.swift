import AppKit
import SwiftUI

/// Where a popover opens and how tall its scrolling part may be, chosen from the screen space
/// around its anchor. AppKit only fits a popover to the screen when it is shown; content that
/// grows afterwards (late data) extends past the screen edge instead of moving the popover.
struct PopoverPlacement: Equatable {
    var edge: Edge
    var listHeight: CGFloat

    static let fallback = PopoverPlacement(edge: .trailing, listHeight: PopoverPlacement.preferredListHeight)
    static let preferredListHeight: CGFloat = 340
    /// Everything in the limits popover except the bucket list, plus arrow and screen margin.
    static let chromeHeight: CGFloat = 300
    static let minimumListHeight: CGFloat = 120

    /// `anchor` and `visible` are screen rectangles (origin bottom-left).
    static func choose(anchor: CGRect, visible: CGRect) -> PopoverPlacement {
        let full = chromeHeight + preferredListHeight
        let below = anchor.midY - visible.minY
        let above = visible.maxY - anchor.midY
        // Beside the anchor the popover is centred on it and slid inside the screen when shown,
        // but later growth spreads both ways, so each half needs room.
        if below >= full / 2 && above >= full / 2 { return PopoverPlacement(edge: .trailing, listHeight: preferredListHeight) }
        let spaceAbove = visible.maxY - anchor.maxY
        let spaceBelow = anchor.minY - visible.minY
        if spaceAbove >= full || spaceAbove >= spaceBelow {
            return PopoverPlacement(edge: .top, listHeight: fitted(spaceAbove))
        }
        return PopoverPlacement(edge: .bottom, listHeight: fitted(spaceBelow))
    }

    private static func fitted(_ space: CGFloat) -> CGFloat {
        min(preferredListHeight, max(minimumListHeight, space - chromeHeight))
    }
}

/// A small popover above or below its anchor (composer chips): it opens on the side with more room and its
/// height is capped to that room, so content that arrives after presentation scrolls instead of leaving the screen.
struct CompactPopoverPlacement: Equatable {
    var edge: Edge
    var maxHeight: CGFloat

    static let fallback = CompactPopoverPlacement(edge: .top, maxHeight: 480)
    /// Arrow, popover padding and a gap to the screen edge.
    static let margin: CGFloat = 48
    static let minimumHeight: CGFloat = 160

    /// `anchor` and `visible` are screen rectangles (origin bottom-left).
    static func choose(anchor: CGRect, visible: CGRect) -> CompactPopoverPlacement {
        let above = visible.maxY - anchor.maxY, below = anchor.minY - visible.minY
        let edge: Edge = above >= below ? .top : .bottom
        return CompactPopoverPlacement(edge: edge, maxHeight: max(minimumHeight, max(above, below) - margin))
    }
}

/// Exposes the screen frame of the view it backs, for placing popovers attached to it.
final class ScreenFrameProbe {
    fileprivate weak var view: NSView?

    private var frames: (anchor: CGRect, visible: CGRect)? {
        guard let view, let window = view.window, let screen = window.screen ?? NSScreen.main else { return nil }
        return (window.convertToScreen(view.convert(view.bounds, to: nil)), screen.visibleFrame)
    }

    var placement: PopoverPlacement {
        frames.map { PopoverPlacement.choose(anchor: $0.anchor, visible: $0.visible) } ?? .fallback
    }

    var compactPlacement: CompactPopoverPlacement {
        frames.map { CompactPopoverPlacement.choose(anchor: $0.anchor, visible: $0.visible) } ?? .fallback
    }
}

/// A popover's content at a height fixed when it opens. A SwiftUI popover that changes height after it is shown
/// grows downward from its top edge (seen on macOS 26: a popover above a composer chip ran 323 pt past the screen
/// bottom), so content is measured before presentation and anything added later scrolls inside this frame.
struct FixedHeightPopover<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView { content }.scrollBounceBehavior(.basedOnSize).frame(height: height)
    }

    /// The natural height of `view`, capped to the room the placement allows.
    @MainActor static func height(of view: some View, placement: CompactPopoverPlacement) -> CGFloat {
        let natural = NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true)).fittingSize.height
        return min(max(natural, 1), placement.maxHeight)
    }
}

struct ScreenFrameReader: NSViewRepresentable {
    let probe: ScreenFrameProbe

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        probe.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { probe.view = view }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
