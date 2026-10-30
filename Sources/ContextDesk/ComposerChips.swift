import SwiftUI
import ContextTranscript

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
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.ui(size: 11, weight: .medium)) }
            Text(title).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(.ui(size: 8, weight: .bold)).foregroundStyle(.tertiary) }
        }
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
                .padding(.horizontal, 9).frame(height: 28)
                .background(configuration.isPressed ? DeskPalette.selection : hovering && isEnabled ? DeskPalette.subtle : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
        }
    }
}
