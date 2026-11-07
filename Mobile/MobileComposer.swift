import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

/// The message composer of one chat: photo strip, settings chips, input and the trailing action.
///
/// Extension points for new controls:
/// - `MobileComposerChips`: per-chat choices shown above the field (role or access, model).
/// - `MobileComposerAction`: the trailing button (Send; while the agent works, Stop for an empty draft,
///   otherwise Queue with Interrupt and send and Stop on a long press).
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
    /// The clipboard holds an image the user has not pasted here yet (a screenshot after "Copy and Delete").
    @State private var clipboardHasImage = false
    @State private var pastedChangeCount = -1

    private var key: MobileChatKey { MobileChatKey(device: device.id, chat: chat.id) }
    private var draftKey: String { device.id + ":" + chat.id }
    private var draft: Binding<String> {
        Binding(get: { model.drafts[draftKey] ?? "" }, set: { model.drafts[draftKey] = $0 })
    }
    private var photos: [RemotePhoto] { model.photoDrafts[draftKey] ?? [] }
    private var hasContent: Bool { !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty }
    private var canAddPhotos: Bool {
        !loadingPhotos && photos.count < RemotePhoto.maximumCount && chat.supportsPhotos == true && chat.readOnly != true && !model.isBlocked(key)
    }

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
                if clipboardHasImage && canAddPhotos {
                    // The system Paste button reads the clipboard without the "Allow Paste" prompt.
                    HStack(spacing: 8) {
                        Label(L10n.text("Фото в буфере обмена", "Photo on the clipboard"), systemImage: "photo.on.rectangle")
                            .font(.caption).foregroundStyle(.secondary)
                        PasteButton(supportedContentTypes: [.image]) { providers in
                            Task { @MainActor in
                                pastedChangeCount = UIPasteboard.general.changeCount; clipboardHasImage = false
                                await addPhotos(from: providers)
                            }
                        }
                        .labelStyle(.titleAndIcon).buttonBorderShape(.capsule).controlSize(.small)
                        .accessibilityIdentifier("paste-photo")
                    }
                }
                if chat.running && hasContent && chat.canQueue == true && chat.canInterrupt == true && !model.isBlocked(key) {
                    Text(L10n.text("Удерживай «В очередь», чтобы прервать и отправить.", "Hold Queue to interrupt and send."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
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
                    MobileComposerAction(model: model, device: device, chat: chat, canSend: !loadingPhotos && hasContent, send: submit(kind:))
                }
                .disabled(model.isBlocked(key))
            }
        }
        .task(id: photoSelection) { await preparePhotos() }
        // Images dropped on the chat screen (`MobileChatView`) are prepared here like picked photos.
        .onChange(of: model.photoDrops[draftKey]?.count ?? 0, initial: true) { _, count in
            guard count > 0, let providers = model.photoDrops.removeValue(forKey: draftKey) else { return }
            Task { await addPhotos(from: providers) }
        }
        .onAppear(perform: refreshClipboard)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in refreshClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refreshClipboard() }
    }

    /// `hasImages` only detects the type; it reads nothing and shows no prompt.
    private func refreshClipboard() {
        let pasteboard = UIPasteboard.general
        clipboardHasImage = pasteboard.hasImages && pasteboard.changeCount != pastedChangeCount
    }

    /// Images from a drop or the Paste button, prepared like picked photos, up to the photo limit.
    private func addPhotos(from providers: [NSItemProvider]) async {
        let images = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        guard !images.isEmpty else { return }
        loadingPhotos = true; photoError = nil
        defer { loadingPhotos = false }
        do {
            var prepared: [RemotePhoto] = []
            for provider in images.prefix(max(0, RemotePhoto.maximumCount - photos.count)) {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    _ = provider.loadDataRepresentation(for: .image) { data, error in
                        if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? RemoteFailure.invalidPhoto) }
                    }
                }
                prepared.append(try Self.preparePhoto(data))
            }
            guard !prepared.isEmpty, photos.count + prepared.count <= RemotePhoto.maximumCount else { throw RemoteFailure.invalidPhoto }
            model.photoDrafts[draftKey, default: []].append(contentsOf: prepared)
        } catch { photoError = error.localizedDescription }
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

    /// `send`, or for a working chat `queue` / `interrupt`; the draft clears only after the command is stored.
    private func submit(kind: String) {
        let text = draft.wrappedValue
        let submittedPhotos = photos
        Task {
            if await model.send(device: device, chat: chat, kind: kind, text: text, photos: submittedPhotos) {
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
                    if let roles = settings.roles, !roles.isEmpty {
                        // As on the desktop: the role's name, then one symbol per add-on that is on.
                        let roleID = settings.options.role ?? settings.projectRole
                        let name = roles.first { $0.id == roleID }?.name ?? L10n.text("Роль", "Role")
                        let addOns = (settings.addOns ?? []).filter { (settings.options.addOns ?? []).contains($0.id) }
                        Button(action: openSettings) {
                            ComposerChip(icon: access == .fullAccess ? "lock.open" : "lock", text: name, badges: addOns.map { $0.symbol ?? "puzzlepiece.extension" })
                        }
                        .accessibilityLabel(([L10n.text("Роль: ", "Role: ") + name] + addOns.map(\.name)).joined(separator: ", "))
                        .accessibilityIdentifier("chat-role-chip")
                    } else {
                        Button(action: openSettings) {
                            ComposerChip(icon: access == .fullAccess ? "lock.open" : "lock", text: access.title)
                        }.accessibilityLabel(L10n.text("Доступ: ", "Access: ") + access.title).accessibilityIdentifier("chat-access-chip")
                    }
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
    /// Small symbols after the text, such as the role's add-ons.
    var badges: [String] = []
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).imageScale(.small).accessibilityHidden(true)
            Text(text)
            ForEach(badges, id: \.self) { Image(systemName: $0).imageScale(.small).accessibilityHidden(true) }
        }
        .font(.caption.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .foregroundStyle(.secondary)
            .contentShape(Capsule())
    }
}

/// The trailing control: Send when idle. While the agent works: Stop for an empty draft; with a draft, Queue
/// (tap) and Interrupt and send and Stop (long press), each only when the Mac offers it for this chat.
struct MobileComposerAction: View {
    @ObservedObject var model: MobileModel
    let device: RemoteDevice
    let chat: RemoteChat
    let canSend: Bool
    let send: (String) -> Void
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 34
    var body: some View {
        let key = MobileChatKey(device: device.id, chat: chat.id)
        let enabled = canSend && !model.pendingSettings(device: device.id, chat: chat.id)
        Group {
            if model.isSending(key) {
                ProgressView().frame(width: size, height: size)
            } else if chat.running && enabled && chat.canQueue == true {
                Menu { busyActions } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "text.line.last.and.arrowtriangle.forward").imageScale(.small)
                        Text(L10n.text("В очередь", "Queue")).lineLimit(1)
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(minHeight: size)
                    .background(Color.accentColor, in: Capsule())
                } primaryAction: { send("queue") }
                .accessibilityLabel(L10n.text("Добавить в очередь", "Add to queue"))
                .accessibilityHint(chat.canInterrupt == true ? L10n.text("Удерживай, чтобы прервать и отправить или остановить агента", "Hold to interrupt and send or to stop the agent") : "")
                .accessibilityIdentifier("queue-message")
            } else if chat.running && enabled && chat.canInterrupt == true {
                Menu { busyActions } label: {
                    Image(systemName: "bolt.circle.fill").font(.system(size: size)).symbolRenderingMode(.hierarchical).foregroundStyle(.orange)
                }
                .accessibilityLabel(L10n.text("Действия с работающим чатом", "Working chat actions")).accessibilityIdentifier("busy-actions")
            } else if chat.running {
                Button { Task { _ = await model.send(device: device, chat: chat, kind: "stop") } } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: size)).symbolRenderingMode(.hierarchical).foregroundStyle(.red)
                }
                .accessibilityLabel(L10n.text("Остановить", "Stop")).accessibilityIdentifier("stop-agent")
            } else {
                Button { send("send") } label: {
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
    @ViewBuilder private var busyActions: some View {
        if chat.canInterrupt == true {
            Button { send("interrupt") } label: {
                Label(L10n.text("Прервать и отправить", "Interrupt and send"), systemImage: "bolt.fill")
            }.accessibilityIdentifier("interrupt-and-send")
        }
        if chat.canQueue == true {
            Button { send("queue") } label: {
                Label(L10n.text("Добавить в очередь", "Add to queue"), systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }
        Divider()
        Button(role: .destructive) { Task { _ = await model.send(device: device, chat: chat, kind: "stop") } } label: {
            Label(L10n.text("Остановить агента", "Stop the agent"), systemImage: "stop.circle")
        }.accessibilityIdentifier("stop-agent-menu")
    }
}
