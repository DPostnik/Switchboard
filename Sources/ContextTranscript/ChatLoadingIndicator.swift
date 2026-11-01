import AppKit
import QuartzCore
import ContextCore
import SwiftUI

/// Fixed-size native animation: no per-frame SwiftUI state or layout changes.
public struct ChatLoadingIndicator: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> WorkingIndicatorView { WorkingIndicatorView() }
    public func updateNSView(_ view: WorkingIndicatorView, context: Context) { view.refreshAnimation() }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkingIndicatorView, context: Context) -> CGSize? {
        CGSize(width: 20, height: 20)
    }
}

@MainActor public final class WorkingIndicatorView: NSView {
    private let dot = CALayer()
    public var isWorking = true { didSet { if oldValue != isWorking { refreshAnimation() } } }
    public var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    public var isAnimating: Bool { dot.animation(forKey: "working") != nil }
    public override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        wantsLayer = true
        dot.frame = CGRect(x: 4, y: 4, width: 12, height: 12)
        dot.cornerRadius = 6
        layer?.addSublayer(dot)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(L10n.text("Загрузка", "Loading"))
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshAnimation), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAnimation),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshAnimation() }
    public override func viewDidHide() { super.viewDidHide(); refreshAnimation() }
    public override func viewDidUnhide() { super.viewDidUnhide(); refreshAnimation() }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.backgroundColor = DeskPalette.ns.muted.cgColor
            CATransaction.commit()
        }
    }

    /// Called at visibility/viewport boundaries, never on an animation timer.
    @objc public func refreshAnimation() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        let animate = isWorking && visible && !NSApp.isHidden && !isHiddenOrHasHiddenAncestor
            && !visibleRect.isEmpty && !reduceMotion
        guard animate != isAnimating else { return }
        if animate {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.75; scale.toValue = 1
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.55; opacity.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [scale, opacity]; group.duration = 0.8
            group.autoreverses = true; group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(group, forKey: "working")
        } else { dot.removeAnimation(forKey: "working") }
    }
}
