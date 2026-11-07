import SwiftUI
import UIKit

/// One chat: the scrolling transcript, with `MobileChatDock` (notices, approvals, composer) pinned below.
struct MobileChatView: View {
    @ObservedObject var model: MobileModel
    let deviceID: String
    let chatID: String
    @FocusState private var writing: Bool
    @State private var following = true
    @State private var atBottom = true
    @State private var jumpRequest = 0
    @State private var showingChatSettings = false
    @State private var openedFile: OpenedFile?
    /// Height of the whole chat screen above the keyboard; bounds the cards pinned in the dock.
    @State private var screenHeight: CGFloat = 700
    @StateObject private var scrollController = TranscriptScrollController()
    private var draftKey: String { deviceID + ":" + chatID }

    var body: some View {
        if let device = model.devices.first(where: { $0.id == deviceID }), let chat = device.snapshot.chats.first(where: { $0.id == chatID }) {
            let project = device.snapshot.projects.first { $0.id == chat.project }
            VStack(spacing: 0) {
                if !(model.connectionState == .connected && model.onlineMacs.contains(device.id.lowercased())) {
                    ConnectionStatus(model: model, device: device)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .frame(maxWidth: .infinity).background(.bar)
                }
                transcript(device: device, chat: chat, project: project)
            }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MobileChatDock(model: model, device: device, chat: chat, project: project, writing: $writing,
                               cardLimit: max(150, screenHeight * 0.36),
                               openSettings: { showingChatSettings = true }, sent: { jumpRequest += 1 })
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { screenHeight = $0 }
            .navigationTitle(chat.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(chat.title).font(.headline).lineLimit(1)
                        let subtitle = [project?.name, chat.agentTitle(in: project)].compactMap { $0 }.joined(separator: " · ")
                        if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if writing {
                        Button { writing = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                            .accessibilityLabel(L10n.text("Скрыть клавиатуру", "Hide keyboard"))
                    }
                }
            }
            .sheet(isPresented: $showingChatSettings) {
                if let settings = chat.settings {
                    MobileChatSettingsView(model: model, deviceID: deviceID, chatID: chatID, expected: settings, options: settings.options,
                                           granted: project?.settings?.addOns?.map(\.id))
                }
            }
            .sheet(item: $openedFile) { file in
                MobileFileView(model: model, device: device, chat: chat, path: file.path)
            }
            #if targetEnvironment(simulator)
            .onAppear {
                // Visual checks: `-preview-file docs/plan.md` opens the viewer with synthetic content;
                // `-preview-chat-settings` opens Chat settings.
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "-preview-file"), index + 1 < arguments.count { openedFile = OpenedFile(path: arguments[index + 1]) }
                if arguments.contains("-preview-chat-settings") { showingChatSettings = true }
            }
            #endif
        } else if let command = model.commands.first(where: { $0.device == deviceID && $0.chat == chatID && $0.createsChat })
                    ?? model.receipt(MobileChatKey(device: deviceID, chat: chatID)).flatMap({ $0.createsChat ? $0 : nil }) {
            MobileNewChatPending(model: model, command: command)
        } else {
            ContentUnavailableView(L10n.text("Чат недоступен", "Chat unavailable"), systemImage: "bubble.left",
                description: Text(L10n.text("Проверь выбранные проекты на Mac.", "Check the selected projects on your Mac.")))
        }
    }

    private func transcript(device: RemoteDevice, chat: RemoteChat, project: RemoteProject?) -> some View {
        let lastCommand = model.commands.first { $0.chat == chatID && $0.device == deviceID && $0.kind != "file" }
        let draft = Binding(get: { model.drafts[draftKey] ?? "" }, set: { model.drafts[draftKey] = $0 })
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(L10n.text("Последние сообщения · полная история на Mac", "Recent messages · full history on Mac"))
                            .font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 8)
                        if chat.messages.isEmpty {
                            ContentUnavailableView(L10n.text("Пока нет сообщений", "No messages yet"), systemImage: "bubble.left.and.bubble.right",
                                description: Text(L10n.text("Напиши первое сообщение — агент ответит здесь.", "Write the first message; the agent answers here.")))
                                .padding(.top, 40)
                        }
                        let lastUser = chat.messages.last { $0.role == "user" }?.id
                        let answerEnds = chat.answerEnds
                        ForEach(chat.messages) { message in
                            MessageBubble(message: message, showsActions: answerEnds.contains(message.id),
                                          openFile: project?.canReadFiles == true ? { openedFile = OpenedFile(path: $0) } : nil)
                                .environment(\.quoteSelection, QuoteSelectionAction { selection in
                                    draft.wrappedValue = QuoteSelectionAction.appending(selection, to: draft.wrappedValue)
                                    writing = true
                                })
                            if message.id == lastUser, let status = sendStatus(lastCommand, chat: chat) {
                                Text(status).font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, -14)
                                    .accessibilityIdentifier("send-status")
                            }
                        }
                        if lastUser == nil, let status = sendStatus(lastCommand, chat: chat) {
                            Text(status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityIdentifier("send-status")
                        }
                        // Queued messages waiting for the Mac are listed above the composer; their outcome shows here.
                        if let command = lastCommand, !["send", "create"].contains(command.kind), command.approval == nil,
                           !(["queue", "interrupt"].contains(command.kind) && ["pending", "claimed"].contains(command.status)) {
                            Text(command.kind == "configure" && command.status == "submitted" ? L10n.text("Настройки сохранены", "Settings saved") : MobileText.command(command.status, kind: command.kind))
                                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityIdentifier("command-status")
                        }
                        Color.clear.frame(height: 1).id("tail")
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: TranscriptBottomKey.self, value: geometry.frame(in: .named("transcript")).maxY)
                            })
                    }.padding(.horizontal, 16).padding(.bottom, 12)
                        .frame(width: viewport.size.width)
                        .background(TranscriptScrollProbe(controller: scrollController))
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: TranscriptHeightKey.self, value: geometry.size.height)
                        })
                }
                .coordinateSpace(name: "transcript")
                .accessibilityIdentifier("conversation-scroll")
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture().onChanged { _ in following = false })
                .onPreferenceChange(TranscriptBottomKey.self) { bottom in
                    atBottom = bottom <= viewport.size.height + 24 && bottom >= 0
                    if atBottom { following = true }
                }
                .onPreferenceChange(TranscriptHeightKey.self) { _ in
                    if following { proxy.scrollTo("tail", anchor: .bottom) }
                }
                .onChange(of: viewport.size.height) { _, _ in
                    if following { proxy.scrollTo("tail", anchor: .bottom) }
                }
                .onChange(of: jumpRequest) { _, _ in
                    following = true
                    proxy.scrollTo("tail", anchor: .bottom)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        Button {
                            following = true
                            if !scrollController.jumpToBottom() { proxy.scrollTo("tail", anchor: .bottom) }
                        } label: {
                            Image(systemName: "arrow.down").font(.headline).frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain).foregroundStyle(.primary)
                        .padding(16).accessibilityLabel(L10n.text("К последнему сообщению", "Jump to latest message"))
                        .accessibilityIdentifier("jump-to-latest")
                    }
                }
            }
        }
    }

    /// Status of the last message sent from the phone, shown under it until the agent takes over.
    private func sendStatus(_ command: RemoteCommand?, chat: RemoteChat) -> String? {
        guard let command, ["send", "create"].contains(command.kind) else { return nil }
        if command.status == "submitted" && (chat.running || chat.messages.last?.role != "user") { return nil }
        return MobileText.command(command.status)
    }
}

/// A chat created from the phone that the Mac has not published yet.
struct MobileNewChatPending: View {
    @ObservedObject var model: MobileModel
    let command: RemoteCommand
    var body: some View {
        let receipt = model.receipt(MobileChatKey(command))
        ScrollView {
            VStack(spacing: 14) {
                if receipt == nil && ["pending", "claimed", "submitted"].contains(command.status) { ProgressView() }
                else { Image(systemName: "bubble.left.and.text.bubble.right").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true) }
                Text(L10n.text("Новый чат", "New chat")).font(.title2.weight(.semibold))
                Text(receipt == nil ? MobileText.command(command.status) : L10n.text("Доставка не подтверждена", "Delivery unconfirmed"))
                    .foregroundStyle(.secondary).accessibilityIdentifier("new-chat-status")
                if !command.text.isEmpty {
                    Text(command.text).font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if receipt.map({ !model.isUndelivered($0) }) ?? true {
                    Text(L10n.text("Чат откроется после обновления с Mac. Команда не отправляется повторно.", "The chat opens when your Mac publishes it. The command is not sent again."))
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                MobileDeliveryNotice(model: model, key: MobileChatKey(command), receipt: receipt)
            }
            .padding(24).frame(maxWidth: .infinity)
        }
        .navigationTitle(L10n.text("Новый чат", "New chat")).navigationBarTitleDisplayMode(.inline)
    }
}

private struct TranscriptScrollProbe: UIViewRepresentable {
    let controller: TranscriptScrollController
    func makeUIView(context: Context) -> Probe {
        let view = Probe(); view.controller = controller; view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { view.attach() }
    final class Probe: UIView {
        weak var controller: TranscriptScrollController?
        override func didMoveToWindow() { super.didMoveToWindow(); attach() }
        override func layoutSubviews() { super.layoutSubviews(); attach() }
        func attach() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { controller?.scrollView = scroll; return }
                ancestor = view.superview
            }
        }
    }
}

private struct TranscriptBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct OpenedFile: Identifiable {
    let id = UUID()
    let path: String
}

struct MessageBubble: View {
    let message: RemoteMessage
    /// Copy, Share and Links under the message: only the end of the agent's reply, not its progress notes.
    var showsActions = true
    /// Set when the Mac can send project files; otherwise path chips copy the path.
    var openFile: ((String) -> Void)?
    @State private var copiedPath = false
    var body: some View {
        if message.role == "user" {
            // The user's words stay literal, like on the Mac.
            HStack(alignment: .top) {
                Spacer(minLength: 56)
                // Long press selects a fragment; the selection menu copies, shares or quotes it.
                SelectableText(text: MarkdownInline.uiKit(plain: message.text), detectsLinks: true, hugsText: true)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("message-text-" + message.id)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("message-" + message.id)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownMessageView(text: message.text, identifier: "message-text-" + message.id)
                if message.truncated == true {
                    Label(L10n.text("Сокращено · полный текст на Mac", "Shortened · full text on Mac"), systemImage: "scissors")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("message-truncated-" + message.id)
                }
                if showsActions { HStack(spacing: 20) {
                    CopyControl(title: L10n.text("Копировать ответ", "Copy answer"), text: message.text, identifier: "copy-message-" + message.id)
                    ShareLink(item: message.text) { Label(L10n.text("Поделиться", "Share"), systemImage: "square.and.arrow.up").font(.caption.weight(.medium)) }
                    let links = Self.links(in: message.text)
                    if !links.isEmpty {
                        Menu { linkMenu(links) } label: { Label(L10n.text("Ссылки", "Links"), systemImage: "link").font(.caption.weight(.medium)) }
                            .accessibilityIdentifier("message-links-" + message.id)
                    }
                    if copiedPath { Text(L10n.text("Путь скопирован", "Path copied")).font(.caption) }
                }.labelStyle(.iconOnly).foregroundStyle(.secondary).buttonStyle(.borderless) }
                else if copiedPath { Text(L10n.text("Путь скопирован", "Path copied")).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                // The file lives on the Mac: open it through the Mac when it can send files, otherwise copy the path.
                guard let path = MarkdownInline.copiedValue(url) ?? MarkdownInline.filePath(url) else { return .systemAction }
                if let openFile { openFile(path); return .handled }
                UIPasteboard.general.string = path
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                copiedPath = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copiedPath = false }
                return .handled
            })
            .accessibilityElement(children: .contain).accessibilityIdentifier("message-" + message.id)
        }
    }
    // The answer itself has no long-press menu: long press selects text instead.
    @ViewBuilder private func linkMenu(_ links: [URL]) -> some View {
        Menu {
            ForEach(links, id: \.self) { url in
                Link(destination: url) { Label(MarkdownInline.shortened(url), systemImage: "safari") }
            }
        } label: { Label(L10n.text("Открыть ссылку", "Open link"), systemImage: "safari") }
        Menu {
            ForEach(links, id: \.self) { url in
                Button(MarkdownInline.shortened(url)) { UIPasteboard.general.url = url }
            }
        } label: { Label(L10n.text("Копировать ссылку", "Copy link"), systemImage: "link.badge.plus") }
    }
    static func links(in text: String) -> [URL] {
        guard text.contains("http"), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var result: [URL] = []
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !result.contains(url) { result.append(url) }
            if result.count == 8 { break }
        }
        return result
    }
}
