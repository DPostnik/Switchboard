import SwiftUI
import PhotosUI
import ImageIO

/// The message composer of one chat: photo strip, settings chips, input and the trailing action.
///
/// Extension points for new controls:
/// - `MobileComposerChips`: per-chat choices shown above the field (access, model; a role picker belongs here).
/// - `MobileComposerAction`: the trailing button (Send, or Stop while the agent works; queue or
///   interrupt-and-send for a busy chat belongs here).
/// Cards that need an answer before the next message (approvals, agent questions) go in `MobileChatDock`, above this view.
struct MobileComposer: View {
    @ObservedObject var model: MobileModel
    let device: RemoteDevice
    let chat: RemoteChat
    let project: RemoteProject?
    var writing: FocusState<Bool>.Binding
    let openSettings: () -> Void
    /// Called after a successful send, e.g. to follow the transcript to the bottom.
    let sent: () -> Void
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var loadingPhotos = false
    @State private var photoError: String?
    @ScaledMetric(relativeTo: .body) private var plusSize: CGFloat = 36

    private var key: MobileChatKey { MobileChatKey(device: device.id, chat: chat.id) }
    private var draftKey: String { device.id + ":" + chat.id }
    private var draft: Binding<String> {
        Binding(get: { model.drafts[draftKey] ?? "" }, set: { model.drafts[draftKey] = $0 })
    }
    private var photos: [RemotePhoto] { model.photoDrafts[draftKey] ?? [] }
    private var hasContent: Bool { !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !photos.isEmpty { photoStrip }
            if loadingPhotos { ProgressView(L10n.text("Подготовка фото…", "Preparing photos…")).font(.caption) }
            if let photoError { Text(photoError).font(.caption).foregroundStyle(.red) }
            if chat.readOnly == true {
                Label(RemoteChat.readOnlyNotice, systemImage: "clock.arrow.circlepath")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6).accessibilityIdentifier("read-only-notice")
            } else {
                MobileComposerChips(model: model, deviceID: device.id, chat: chat, project: project, openSettings: openSettings)
                HStack(alignment: .bottom, spacing: 8) {
                    PhotosPicker(selection: $photoSelection, maxSelectionCount: max(1, RemotePhoto.maximumCount - photos.count), matching: .images) {
                        Image(systemName: "plus").font(.body.weight(.semibold))
                            .frame(width: plusSize, height: plusSize)
                            .background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                    .accessibilityLabel(L10n.text("Добавить фото", "Add photos")).accessibilityIdentifier("add-photos")
                    .disabled(loadingPhotos || photos.count >= RemotePhoto.maximumCount || chat.supportsPhotos != true)
                    TextField(L10n.text("Сообщение…", "Message…"), text: draft, axis: .vertical)
                        .lineLimit(1...6).focused(writing)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
                        .accessibilityIdentifier("message-input")
                    MobileComposerAction(model: model, device: device, chat: chat, canSend: !loadingPhotos && hasContent, send: submit)
                }
                .disabled(model.isBlocked(key))
            }
        }
        .task(id: photoSelection) { await preparePhotos() }
    }

    private var photoStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(photos) { photo in
                    if let image = UIImage(data: photo.data) {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Button { model.photoDrafts[draftKey]?.removeAll { $0.id == photo.id } } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .padding(2)
                                .accessibilityLabel(L10n.text("Удалить фото", "Remove photo"))
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(L10n.text("Фото", "Photo"))
                    }
                }
            }.padding(.top, 2)
        }
        .scrollIndicators(.hidden)
        .frame(height: 64)
        .disabled(model.isBlocked(key) || loadingPhotos)
    }

    private func submit() {
        let text = draft.wrappedValue
        let submittedPhotos = photos
        Task {
            if await model.send(device: device, chat: chat, kind: "send", text: text, photos: submittedPhotos) {
                if draft.wrappedValue == text { draft.wrappedValue = ""; writing.wrappedValue = false }
                model.photoDrafts[draftKey]?.removeAll { photo in submittedPhotos.contains { $0.id == photo.id } }
                sent()
            }
        }
    }

    private func preparePhotos() async {
        guard !photoSelection.isEmpty else { return }
        loadingPhotos = true; photoError = nil
        defer { loadingPhotos = false }
        do {
            var prepared: [RemotePhoto] = []
            for item in photoSelection {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw RemoteFailure.invalidPhoto }
                try Task.checkCancellation()
                prepared.append(try Self.preparePhoto(data))
            }
            try Task.checkCancellation()
            guard photos.count + prepared.count <= RemotePhoto.maximumCount else { throw RemoteFailure.invalidPhoto }
            model.photoDrafts[draftKey, default: []].append(contentsOf: prepared)
            photoSelection = []
        } catch is CancellationError { }
        catch { photoError = error.localizedDescription; photoSelection = [] }
    }

    static func preparePhoto(_ data: Data) throws -> RemotePhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { throw RemoteFailure.invalidPhoto }
        let image = UIImage(cgImage: thumbnail)
        for quality in [0.85, 0.65, 0.45, 0.25] {
            if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= RemotePhoto.maximumBytes {
                let photo = RemotePhoto(data: jpeg); try photo.validate(); return photo
            }
        }
        throw RemoteFailure.invalidPhoto
    }
}

/// Per-chat choices above the field. Each chip opens Chat settings.
struct MobileComposerChips: View {
    @ObservedObject var model: MobileModel
    let deviceID: String
    let chat: RemoteChat
    let project: RemoteProject?
    let openSettings: () -> Void
    var body: some View {
        if let settings = chat.settings {
            let access = settings.options.access ?? settings.projectAccess
            let modelName = project?.models?.first { $0.id == settings.options.model }?.name ?? settings.options.model
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    Button(action: openSettings) {
                        ComposerChip(icon: access == .fullAccess ? "lock.open" : "lock", text: access.title)
                    }.accessibilityLabel(L10n.text("Доступ: ", "Access: ") + access.title).accessibilityIdentifier("chat-access-chip")
                    Button(action: openSettings) {
                        ComposerChip(icon: "cpu", text: modelName.isEmpty ? L10n.text("Модель", "Model") : modelName)
                    }.accessibilityLabel(L10n.text("Настройки чата", "Chat settings") + ": " + modelName).accessibilityIdentifier("chat-settings")
                    if model.pendingSettings(device: deviceID, chat: chat.id) {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel(L10n.text("Настройки ожидают Mac", "Settings waiting for Mac"))
                    }
                }
                .buttonStyle(.plain)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct ComposerChip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).imageScale(.small).accessibilityHidden(true)
            Text(text)
        }
        .font(.caption.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .foregroundStyle(.secondary)
            .contentShape(Capsule())
    }
}

/// The trailing control: Send when idle, Stop while the agent works.
struct MobileComposerAction: View {
    @ObservedObject var model: MobileModel
    let device: RemoteDevice
    let chat: RemoteChat
    let canSend: Bool
    let send: () -> Void
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 34
    var body: some View {
        let key = MobileChatKey(device: device.id, chat: chat.id)
        Group {
            if model.isSending(key) {
                ProgressView().frame(width: size, height: size)
            } else if chat.running {
                Button { Task { _ = await model.send(device: device, chat: chat, kind: "stop") } } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: size)).symbolRenderingMode(.hierarchical).foregroundStyle(.red)
                }
                .accessibilityLabel(L10n.text("Остановить", "Stop")).accessibilityIdentifier("stop-agent")
            } else {
                let enabled = canSend && !model.pendingSettings(device: device.id, chat: chat.id)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: size))
                        .foregroundStyle(enabled ? Color.accentColor : Color(.tertiaryLabel))
                }
                .disabled(!enabled)
                .accessibilityLabel(L10n.text("Отправить", "Send")).accessibilityIdentifier("send-message")
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
    }
}
