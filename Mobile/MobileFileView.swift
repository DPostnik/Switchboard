import SwiftUI
import UIKit

/// Read-only view of one project file, fetched through the Mac on demand.
/// Markdown is rendered, other text is shown as is, PDF pages and images arrive as JPEG.
struct MobileFileView: View {
    @ObservedObject var model: MobileModel
    let device: RemoteDevice
    let chat: RemoteChat
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var command: String?
    @State private var file: RemoteFile?
    @State private var failure: String?
    @State private var attempt = 0
    @State private var copied = false
    private var status: String? { command.flatMap { id in model.commands.first { $0.id == id }?.status } }

    var body: some View {
        NavigationStack {
            Group {
                if let file, file.kind != .failure { content(file) }
                else if let message = failure ?? file?.failure?.message() { failed(message) }
                else { waiting }
            }
            .navigationTitle(file?.name ?? (path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Готово", "Done")) { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { UIPasteboard.general.string = file?.path ?? path; copied = true } label: {
                            Label(L10n.text("Копировать путь", "Copy path"), systemImage: "doc.on.doc")
                        }
                        if let text = file?.text {
                            Button { UIPasteboard.general.string = text; copied = true } label: {
                                Label(L10n.text("Копировать текст", "Copy text"), systemImage: "doc.plaintext")
                            }
                            ShareLink(item: text) { Label(L10n.text("Поделиться", "Share"), systemImage: "square.and.arrow.up") }
                        }
                    } label: { Image(systemName: copied ? "checkmark" : "ellipsis.circle") }
                        .accessibilityLabel(L10n.text("Действия с файлом", "File actions"))
                }
            }
        }
        .accessibilityIdentifier("file-viewer")
        .task(id: attempt) { await request() }
        .task(id: status) { await receive() }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5)); copied = false
        }
    }

    private var waiting: some View {
        let online = model.connectionState == .connected && model.onlineMacs.contains(device.id.lowercased())
        return VStack(spacing: 14) {
            ProgressView()
            Text(status == "claimed" ? L10n.text("Mac читает файл…", "The Mac is reading the file…")
                 : online ? L10n.text("Запрашиваем файл у Mac…", "Requesting the file from the Mac…")
                 : L10n.text("Mac недоступен. Файл откроется, когда Mac выйдет на связь.", "The Mac is unavailable. The file opens when the Mac is back online."))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text(path).font(.system(.footnote, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("file-loading")
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.questionmark").font(.largeTitle).foregroundStyle(.secondary)
            Text(message).multilineTextAlignment(.center).accessibilityIdentifier("file-error")
            Text(file?.path ?? path).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(3).truncationMode(.middle).multilineTextAlignment(.center)
            Button(L10n.text("Запросить ещё раз", "Request again")) { attempt += 1 }.buttonStyle(.bordered)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func content(_ file: RemoteFile) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text(file.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                if let note = note(file) {
                    Label(note, systemImage: "scissors").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("file-truncated")
                }
                switch file.kind {
                case .markdown:
                    let blocks = MarkdownBlocks.parse(file.text ?? "")
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        MarkdownBlockView(block: block, depth: 0).identified(index == 0 ? "file-content" : nil)
                    }
                case .text:
                    let chunks = Self.chunks(file.text ?? "")
                    ForEach(Array(chunks.enumerated()), id: \.offset) { index, chunk in
                        SelectableText(text: MarkdownInline.uiKit(plain: chunk, style: .footnote, monospaced: true))
                            .identified(index == 0 ? "file-content" : nil)
                    }
                case .pages:
                    let pages = file.pages ?? []
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, data in
                        if let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.separator)))
                                .accessibilityLabel(L10n.text("Страница \(index + 1)", "Page \(index + 1)"))
                                .identified(index == 0 ? "file-content" : nil)
                            if pages.count > 1 {
                                Text(L10n.text("Страница \(index + 1)", "Page \(index + 1)")).font(.caption2).foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                case .failure: EmptyView()
                }
            }.padding()
        }
        .environment(\.openURL, OpenURLAction { url in
            // Paths inside the file are relative to it, not to the project: copy them.
            guard let value = MarkdownInline.copiedValue(url) ?? MarkdownInline.filePath(url) else { return .systemAction }
            UIPasteboard.general.string = value; copied = true
            return .handled
        })
    }

    private func note(_ file: RemoteFile) -> String? {
        guard file.truncated == true else { return nil }
        if file.kind == .pages, let total = file.pageCount {
            let shown = file.pages?.count ?? 0
            return L10n.text("Показаны первые \(shown) из \(total) страниц. Полный файл на Mac.", "Showing the first \(shown) of \(total) pages. The full file is on the Mac.")
        }
        let total = file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let shown = ByteCountFormatter.string(fromByteCount: Int64(RemoteFile.textBytes), countStyle: .file)
        return total.map { L10n.text("Показано начало файла: \(shown) из \($0). Полный файл на Mac.", "Showing the start of the file: \(shown) of \($0). The full file is on the Mac.") }
            ?? L10n.text("Показано начало файла. Полный файл на Mac.", "Showing the start of the file. The full file is on the Mac.")
    }

    /// Long text renders in pieces so scrolling stays smooth.
    static func chunks(_ text: String, lines: Int = 120) -> [String] {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return stride(from: 0, to: max(all.count, 1), by: lines).map { all[$0..<min($0 + lines, all.count)].joined(separator: "\n") }
    }

    private func request() async {
        file = nil; failure = nil; command = nil
        do { command = try await model.requestFile(device: device, chat: chat, path: path) }
        catch { failure = error.localizedDescription }
    }

    private func receive() async {
        guard let command, file == nil, failure == nil, let status else { return }
        switch status {
        case "submitted":
            do {
                if let value = try await model.takeFile(command) { file = value }
                else { failure = RemoteFile.Failure.unreadable.message() }
            } catch { failure = error.localizedDescription }
        case "rejected":
            failure = L10n.text("Mac отклонил запрос: чат или проект недоступен.", "The Mac declined the request: the chat or project is unavailable.")
        case "uncertain":
            failure = L10n.text("Mac не смог передать файл.", "The Mac could not send the file.")
        default: break
        }
    }
}
