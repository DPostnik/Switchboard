import AppKit
import QuartzCore
import SwiftUI
import ContextCore

/// Horizontal pointer direction for the buddy's eyes, -1 (left) … 1 (right).
/// Kept apart from the island state so mouse moves redraw only the buddy.
@MainActor final class NotchLook: ObservableObject {
    @Published var x: CGFloat = 0
}

/// Switchboard's own island character: a coral squircle whose face follows the agents.
/// Sleepy and still when idle, reading while they work, wide-eyed and wiggling when one needs the user,
/// happy with a jump when a turn finishes. Core Animation runs every loop in the render server,
/// so a busy main thread never makes it stutter; the loops ask for at most 30 fps, which is plenty
/// for a 20-point face. Reduce Motion keeps the faces and the blink and drops every movement.
struct DeskBuddy: NSViewRepresentable {
    enum Mood { case idle, working, waiting, happy }
    let mood: Mood
    let size: CGFloat
    var celebratedAt: Date?
    @ObservedObject var look: NotchLook
    var paused = false

    init(summary: NotchSummary, size: CGFloat, celebratedAt: Date?, look: NotchLook, paused: Bool) {
        mood = switch summary {
        case .idle: .idle
        case .working: .working
        case .waiting: .waiting
        case .finished: .happy
        }
        self.size = size; self.celebratedAt = celebratedAt; self.look = look; self.paused = paused
    }

    func makeNSView(context: Context) -> DeskBuddyView { DeskBuddyView() }
    func updateNSView(_ view: DeskBuddyView, context: Context) {
        view.update(mood: mood, size: size, celebratedAt: celebratedAt, gaze: look.x, paused: paused)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DeskBuddyView, context: Context) -> CGSize? {
        CGSize(width: size * 1.4, height: size * 1.4)
    }
}

final class DeskBuddyView: NSView {
    private let glow = CAShapeLayer()
    private let jump = CALayer()
    private let motion = CALayer()
    private let body = CAGradientLayer()
    private let face = CALayer()
    private let eyes = [CAShapeLayer(), CAShapeLayer()]
    private let highlights = [CAShapeLayer(), CAShapeLayer()]
    private let mouth = CAShapeLayer()
    private let cheeks = [CAShapeLayer(), CAShapeLayer()]
    private var mood: DeskBuddy.Mood?
    private var size: CGFloat = 0
    private var celebratedAt: Date?
    private var gaze: CGFloat = 0
    private var reduceMotion = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let root = CALayer()
        root.isGeometryFlipped = true
        // Layer-hosting: the view owns this layer tree and never draws through AppKit.
        layer = root
        wantsLayer = true
        root.addSublayer(glow)
        root.addSublayer(jump)
        jump.addSublayer(motion)
        motion.addSublayer(body)
        motion.addSublayer(face)
        for (eye, highlight) in zip(eyes, highlights) { face.addSublayer(eye); eye.addSublayer(highlight) }
        cheeks.forEach(face.addSublayer)
        face.addSublayer(mouth)
        // Selector-based, so the center drops the observer when the view goes away.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    @objc nonisolated private func displayOptionsChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            guard reduce != reduceMotion else { return }
            reduceMotion = reduce
            rebuild()
        }
    }

    func update(mood: DeskBuddy.Mood, size: CGFloat, celebratedAt: Date?, gaze: CGFloat, paused: Bool) {
        if mood != self.mood || size != self.size {
            self.mood = mood; self.size = size
            rebuild()
        }
        if let celebratedAt, celebratedAt != self.celebratedAt, Date().timeIntervalSince(celebratedAt) < 1, !reduceMotion { celebrate() }
        self.celebratedAt = celebratedAt
        if gaze != self.gaze { self.gaze = gaze; applyGaze() }
        // A hidden island freezes the buddy instead of animating something nobody sees.
        layer?.speed = paused ? 0 : 1
    }

    private func rebuild() {
        guard let mood else { return }
        let s = size, box = s * 1.4, side = s * 0.92
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        [glow, jump, motion, face, mouth].forEach { $0.removeAllAnimations() }
        (eyes + highlights + cheeks).forEach { $0.removeAllAnimations() }

        let center = CGPoint(x: box / 2, y: box / 2 + s * 0.05)
        jump.frame = CGRect(x: 0, y: 0, width: box, height: box)
        motion.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        motion.position = center
        body.frame = motion.bounds
        body.cornerRadius = side * 0.38
        body.cornerCurve = .continuous
        let waiting = mood == .waiting
        body.colors = waiting
            ? [NSColor(red: 1, green: 0.66, blue: 0.38, alpha: 1).cgColor, NSColor(red: 0.95, green: 0.45, blue: 0.2, alpha: 1).cgColor]
            : [NSColor(red: 0.96, green: 0.64, blue: 0.49, alpha: 1).cgColor, NSColor(red: 0.85, green: 0.46, blue: 0.32, alpha: 1).cgColor]
        face.frame = motion.bounds

        let radius = s * 0.6
        glow.frame = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        glow.path = CGPath(ellipseIn: glow.bounds, transform: nil)
        glow.fillColor = NSColor.orange.withAlphaComponent(0.45).cgColor
        glow.isHidden = !waiting

        let ink = NSColor(white: 0.13, alpha: 1).cgColor
        let line = max(1.2, s * 0.07)
        let eyeY = side / 2 - s * 0.06
        for (index, eye) in eyes.enumerated() {
            let x = side / 2 + (index == 0 ? -1 : 1) * s * 0.2
            let width = s * (waiting ? 0.15 : 0.12), height = s * (waiting ? 0.3 : 0.24)
            eye.bounds = CGRect(x: 0, y: 0, width: s * 0.2, height: height)
            eye.position = CGPoint(x: x, y: eyeY)
            let local = eye.bounds
            let path = CGMutablePath()
            switch mood {
            case .idle:
                path.move(to: CGPoint(x: local.midX - s * 0.08, y: local.midY))
                path.addQuadCurve(to: CGPoint(x: local.midX + s * 0.08, y: local.midY), control: CGPoint(x: local.midX, y: local.midY + s * 0.06))
            case .happy:
                path.move(to: CGPoint(x: local.midX - s * 0.08, y: local.midY + s * 0.04))
                path.addQuadCurve(to: CGPoint(x: local.midX + s * 0.08, y: local.midY + s * 0.04), control: CGPoint(x: local.midX, y: local.midY - s * 0.1))
            case .working, .waiting:
                path.addRoundedRect(in: CGRect(x: local.midX - width / 2, y: local.midY - height / 2, width: width, height: height),
                                    cornerWidth: width / 2, cornerHeight: width / 2)
            }
            eye.path = path
            let stroked = mood == .idle || mood == .happy
            eye.fillColor = stroked ? nil : ink
            eye.strokeColor = stroked ? ink : nil
            eye.lineWidth = line
            eye.lineCap = .round

            let highlight = highlights[index], dot = width * 0.4
            highlight.path = CGPath(ellipseIn: CGRect(x: local.midX - width * 0.15, y: local.midY - height * 0.32, width: dot, height: dot), transform: nil)
            highlight.fillColor = NSColor.white.cgColor
            highlight.isHidden = !waiting
        }

        let mouthY = side / 2 + s * 0.17
        let mouthPath = CGMutablePath()
        switch mood {
        case .waiting:
            let o = s * 0.09
            mouthPath.addEllipse(in: CGRect(x: side / 2 - o / 2, y: mouthY - o / 2, width: o, height: o * 1.1))
            mouth.lineWidth = max(1, s * 0.055)
        case .happy:
            mouthPath.move(to: CGPoint(x: side / 2 - s * 0.1, y: mouthY - s * 0.02))
            mouthPath.addQuadCurve(to: CGPoint(x: side / 2 + s * 0.1, y: mouthY - s * 0.02), control: CGPoint(x: side / 2, y: mouthY + s * 0.1))
            mouth.lineWidth = max(1.1, s * 0.06)
        case .idle, .working: break
        }
        mouth.path = mouthPath
        mouth.fillColor = nil
        mouth.strokeColor = ink
        mouth.lineCap = .round
        for (index, cheek) in cheeks.enumerated() {
            let x = side / 2 + (index == 0 ? -1 : 1) * s * 0.3
            cheek.path = CGPath(ellipseIn: CGRect(x: x - s * 0.06, y: mouthY - s * 0.06, width: s * 0.12, height: s * 0.07), transform: nil)
            cheek.fillColor = NSColor.systemPink.withAlphaComponent(0.7).cgColor
            cheek.isHidden = mood != .happy
        }

        addLoops(for: mood)
        applyGaze()
    }

    private func addLoops(for mood: DeskBuddy.Mood) {
        let s = size, still = reduceMotion
        // Idle has no loop at all: the sleepy face just rests, so a quiet desk costs no frames.
        switch mood {
        case .idle: break
        case .working:
            if !still {
                motion.add(Self.loop("transform.translation.y", values: [0, s * 0.04, 0, -s * 0.04, 0], duration: 1.05), forKey: "bob")
                // Eyes scan left and right like reading.
                face.add(Self.loop("transform.translation.x", values: [0, s * 0.07, 0, -s * 0.07, 0], duration: 2.85), forKey: "scan")
            }
            eyes.forEach { $0.add(Self.blink(every: 3.7), forKey: "blink") }
        case .waiting:
            // Under Reduce Motion the glow stays lit as a steady ring instead of pulsing.
            if !still {
                motion.add(Self.loop("transform.rotation.z", values: [0, 0.16, -0.16, 0.16, -0.12, 0, 0], keyTimes: [0, 0.05, 0.1, 0.15, 0.22, 0.28, 1], duration: 1.6), forKey: "wiggle")
                let grow = Self.loop("transform.scale", values: [1, 1.58], duration: 1.2, smooth: false)
                let fade = Self.loop("opacity", values: [1, 0], duration: 1.2, smooth: false)
                let pulse = CAAnimationGroup()
                pulse.animations = [grow, fade]; pulse.duration = 1.2; pulse.repeatCount = .infinity
                pulse.preferredFrameRateRange = Self.frameRate
                glow.add(pulse, forKey: "pulse")
            }
            eyes.forEach { $0.add(Self.blink(every: 5.3), forKey: "blink") }
        case .happy:
            if !still { motion.add(Self.loop("transform.translation.y", values: [0, -s * 0.05, 0], duration: 1.05), forKey: "hop") }
        }
    }

    private func applyGaze() {
        // While working the eyes scan on their own; otherwise they follow the pointer.
        let offset = mood == .working ? 0 : gaze * size * 0.08
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        face.setAffineTransform(CGAffineTransform(translationX: offset, y: 0))
        CATransaction.commit()
    }

    private func celebrate() {
        let s = size
        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, -s * 0.35, 0, -s * 0.14, 0]
        hop.keyTimes = [0, 0.28, 0.55, 0.75, 1]
        hop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn),
                               CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        hop.duration = 0.9
        jump.add(hop, forKey: "celebrate")
    }

    /// A small face reads as smooth at 24 fps; capping the loops spares ProMotion displays from 120 Hz redraws.
    private static let frameRate = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 24)

    private static func loop(_ keyPath: String, values: [CGFloat], keyTimes: [NSNumber]? = nil, duration: CFTimeInterval, smooth: Bool = true) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.calculationMode = smooth ? .cubic : .linear
        if !smooth { animation.timingFunction = CAMediaTimingFunction(name: .easeOut) }
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = frameRate
        return animation
    }

    private static func blink(every period: CFTimeInterval) -> CAKeyframeAnimation {
        let closed = 0.13 / period
        let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
        animation.values = [1, 0.15, 1, 1]
        animation.keyTimes = [0, NSNumber(value: closed / 2), NSNumber(value: closed), 1]
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = frameRate
        return animation
    }
}
