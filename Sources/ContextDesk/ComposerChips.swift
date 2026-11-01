import SwiftUI
import ContextTranscript
import ContextCore

/// A flat composer control: title and chevron without a bezel, highlighted on hover.
struct ChipMenu<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        Menu { content } label: {
            ChipLabel(title: title, systemImage: systemImage, chevron: true)
        }
        .menuStyle(.button).buttonStyle(ChipButtonStyle()).menuIndicator(.hidden).fixedSize()
        .pointingHandCursor()
    }
}

struct ChipLabel: View {
    let title: String
    var systemImage: String? = nil
    var chevron = false

    var body: some View {
        HStack(spacing: .ui(5)) {
            if let systemImage { Image(systemName: systemImage).font(.ui(size: 11, weight: .medium)) }
            Text(title).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(.ui(size: 8, weight: .bold)).foregroundStyle(.tertiary) }
        }
    }
}

/// Context use as a small ring beside the send button; a dot marks a prompt cache that expired or is about to.
/// A click opens the "Context and tokens" details.
struct ContextRing: View {
    let usage: UsageSnapshot?
    let claude: Bool
    @State private var showingDetails = false

    /// The ring turns amber from this share of the context window.
    static let highFraction = 0.8

    /// Short summary for the tooltip and VoiceOver: the context share (or "no data") and the cache time.
    static func summary(_ usage: UsageSnapshot?, cache: PromptCacheState?, language: AppLanguage = L10n.language) -> String {
        var parts = [UsageDetail.footer(usage, language: language)]
        if let cache { parts.append(UsageDetail.cacheBadge(cache, language: language)) }
        return parts.joined(separator: " · ")
    }

    /// The summary plus, while the dot is shown, why an expired cache costs more.
    static func help(_ usage: UsageSnapshot?, cache: PromptCacheState?) -> String {
        let summary = summary(usage, cache: cache)
        return cache?.needsAttention == true ? summary + "\n\n" + UsageDetail.cacheHelp : summary
    }

    var body: some View {
        // The cache state depends on the clock, so it is re-read every 30 seconds, as the footer badge did.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let cache = usage?.cacheState(now: context.date)
            Button { showingDetails.toggle() } label: { ring(cache: cache) }
                .buttonStyle(PointerButtonStyle(base: .plain))
                .help(Self.help(usage, cache: cache))
                .accessibilityLabel(Self.summary(usage, cache: cache))
        }
        .popover(isPresented: $showingDetails) { UsageDetail(usage: usage, claude: claude).padding(20).frame(width: 330) }
    }

    /// Text inside the ring and the tooltip: the rounded percentage, "6%", as in the details; nil until the window is known.
    static func percent(_ usage: UsageSnapshot?) -> String? {
        usage?.contextFraction.map { "\(Int(($0 * 100).rounded()))%" }
    }

    private func ring(cache: PromptCacheState?) -> some View {
        let fraction = usage?.contextFraction
        let lineWidth = CGFloat.ui(2)
        let high = (fraction ?? 0) >= Self.highFraction
        return ZStack {
            Circle().stroke(DeskPalette.selection, lineWidth: lineWidth)
            if let fraction, fraction > 0 {
                Circle().trim(from: 0, to: max(0.03, fraction))
                    .stroke(high ? DeskPalette.attention : DeskPalette.accent,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let percent = Self.percent(usage) {
                Text(percent)
                    .font(.ui(size: 8.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(high ? DeskPalette.attention : .secondary)
                    .lineLimit(1).minimumScaleFactor(0.75).padding(.horizontal, .ui(3))
            }
        }
        .frame(width: .ui(26), height: .ui(26))
        .overlay(alignment: .topTrailing) {
            if cache?.needsAttention == true {
                Circle().fill(DeskPalette.attention)
                    .overlay(Circle().stroke(DeskPalette.canvas, lineWidth: 1.5))
                    .frame(width: .ui(7), height: .ui(7))
                    .offset(x: .ui(1), y: -.ui(1))
            }
        }
        .frame(width: .ui(30), height: .ui(30))
        .contentShape(Rectangle())
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ChipBody(configuration: configuration) }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.ui(.callout)).foregroundStyle(isEnabled ? .primary : .secondary)
                .padding(.horizontal, .ui(9)).frame(height: .ui(28))
                .background(configuration.isPressed ? DeskPalette.selection : hovering && isEnabled ? DeskPalette.subtle : .clear,
                            in: Capsule())
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}
