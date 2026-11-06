import AppKit
import ContextCore
import ContextTranscript
import SwiftUI

/// The images named in the draft, above the text: the same numbers as their chips in the text. A click opens the
/// viewer, × removes the image and its chips from the text; removing a chip from the text removes it here.
struct ComposerAttachmentsBar: View {
    @ObservedObject var composer: ComposerState

    var body: some View {
        if !composer.images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(composer.images.enumerated()), id: \.element) { index, url in
                        ComposerAttachmentTile(url: url, number: index + 1,
                                               open: { ImageViewerState.shared.show(url, gallery: composer.images) },
                                               remove: { composer.removeImage(url) })
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12)
            }
            .transition(.opacity)
        }
    }
}

private struct ComposerAttachmentTile: View {
    let url: URL
    let number: Int
    let open: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        let label = L10n.text("Фото \(number)", "Image \(number)")
        Button(action: open) {
            Group {
                if let image = TranscriptImagePaths.thumbnail(url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                Text("\(number)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.55))).padding(4)
            }
        }
        .buttonStyle(.plain)
        .help(url.path + "\n" + L10n.text("\(label): нажмите, чтобы открыть", "\(label): click to open"))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 18, height: 18).background(Circle().fill(Color.black.opacity(0.65)))
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(L10n.text("Убрать из сообщения", "Remove from the message"))
            .accessibilityLabel(L10n.text("Убрать \(label) из сообщения", "Remove \(label) from the message"))
            .offset(x: 6, y: -6)
            .opacity(hovering ? 1 : 0.85)
        }
        .padding(.top, 6).padding(.trailing, 6)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L10n.text("Открыть", "Open"), action: open)
            Button(L10n.text("Скопировать путь", "Copy Path")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)
            }
            Button(L10n.text("Показать в Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button(L10n.text("Убрать из сообщения", "Remove from Message"), action: remove)
        }
        .accessibilityLabel(label)
    }
}
