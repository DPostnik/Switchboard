import AppKit
import SwiftUI

/// Keeps the enclosing scroll view on overlay scrollers whatever the system setting. A legacy scroller
/// draws its own light track and takes a column of the sidebar's width; place this inside the scrolled content.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            guard window != nil else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(styleChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            apply()
        }
        @objc private func styleChanged() {
            // The scroll view applies the new system style in its own observer; override it afterwards.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        func apply() {
            guard let scroll = enclosingScrollView, scroll.scrollerStyle != .overlay else { return }
            scroll.scrollerStyle = .overlay
        }
    }
}
