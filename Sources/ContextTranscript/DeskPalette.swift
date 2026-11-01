import AppKit
import SwiftUI

/// Shared "sage" surfaces for the light SwiftUI shell and native transcript: green-tinted neutrals,
/// one moss accent for actions and unread state, amber for "needs you", clay for errors.
/// AppKit code uses the `ns` variants; SwiftUI uses the `Color` tokens built from them.
public enum DeskPalette {
    // Surfaces
    public static let canvas = Color(nsColor: ns.canvas)
    public static let sidebar = Color(nsColor: ns.sidebar)
    public static let subtle = Color(nsColor: ns.subtle)
    public static let selection = Color(nsColor: ns.selection)
    /// Sidebar row under the pointer or with its context menu open: visible on `sidebar`, lighter than `selection`.
    public static let rowHover = Color(nsColor: ns.rowHover)
    public static let border = Color(nsColor: ns.border)
    /// Focus ring of text fields and the composer.
    public static let focusBorder = Color(nsColor: ns.accentRing)
    public static let ink = Color(nsColor: ns.ink)
    /// Secondary text: captions, metadata, disclosure labels.
    public static let muted = Color(nsColor: ns.muted)
    /// Quieter body text: tool output, quotes.
    public static let inkSoft = Color(nsColor: ns.inkSoft)
    public static let outgoingBubble = ns.outgoingBubble

    // Roles
    public static let accent = Color(nsColor: ns.accent)
    /// Accent text and icons on `accentWash` or light surfaces.
    public static let accentDeep = Color(nsColor: ns.accentDeep)
    public static let accentWash = Color(nsColor: ns.accentWash)
    public static let attention = Color(nsColor: ns.attention)
    public static let attentionWash = Color(nsColor: ns.attentionWash)
    /// Dark text on `attentionWash`.
    public static let attentionInk = Color(nsColor: ns.attentionInk)
    public static let problem = Color(nsColor: ns.problem)
    public static let problemWash = Color(nsColor: ns.problemWash)
    public static let problemInk = Color(nsColor: ns.problemInk)
    public static let browser = Color(nsColor: ns.browser)

    /// Soft shadow under raised surfaces (composer, floating buttons).
    public static let shadow = Color(nsColor: ns.shadow)

    public enum ns {
        public static let canvas = rgb(0xFAFAF7)
        public static let sidebar = rgb(0xEEF0E9)
        public static let subtle = rgb(0xE8EBE3)
        public static let selection = rgb(0xDFE5D8)
        public static let rowHover = rgb(0xE6EADF)
        public static let border = rgb(0xE0E3DA)
        public static let ink = rgb(0x252923)
        public static let muted = rgb(0x7F877A)
        public static let inkSoft = rgb(0x4F574B)
        /// Left bar of quotes.
        public static let quoteBar = rgb(0xC9D3BF)
        public static let outgoingBubble = rgb(0xE6ECDF)
        /// Code blocks and inline code.
        public static let code = rgb(0xF0F2EB)
        public static let accent = rgb(0x5C7A4F)
        public static let accentDeep = rgb(0x4A6640)
        public static let accentWash = rgb(0xE3EAD9)
        public static let accentRing = rgb(0x5C7A4F, alpha: 0.4)
        public static let attention = rgb(0xB7832F)
        public static let attentionWash = rgb(0xF6EFDF)
        public static let attentionInk = rgb(0x5C4519)
        public static let problem = rgb(0xB4553A)
        public static let problemWash = rgb(0xF6E6DF)
        public static let problemInk = rgb(0x6D2F1F)
        public static let browser = rgb(0x3F7F7A)
        public static let shadow = rgb(0x28371F, alpha: 0.09)

        static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
    }
}
