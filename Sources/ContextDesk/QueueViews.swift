import AppKit
import SwiftUI
import ContextCore
import ContextTranscript

/// The open chat's queue above the composer: send now, edit in place, reorder (menu, drag, VoiceOver) and remove.
/// Edits and moves go through the model, which refuses them once the drain has claimed the message.
struct QueuePanel: View {
    @ObservedObject var model: DeskModel
    let columnWidth: CGFloat
    /// Files dropped on a row still go to the draft, as anywhere else in the chat.
    let fileDrop: ChatFileDrop
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editorHeight: CGFloat = 22
    @State private var editorFocused = false
    /// The row being dragged to a new place; only such a drag reorders, any other drag (files) goes to the draft.
    @State private var dragging: String?
    @State private var dropTarget: String?

    var body: some View {
        let queue = model.visibleQueue
        if !queue.isEmpty {
            VStack(alignment: .leading, spacing: .ui(6)) {
                HStack {
                    Text(model.queuePaused ? L10n.text("Очередь приостановлена", "Queue paused") : L10n.text("В очереди · \(queue.count)", "Queued · \(queue.count)"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.queuePaused && model.priorityMessageID == nil {
                        Button(L10n.text("Продолжить", "Resume")) { model.resumeQueue() }.disabled(model.busy || !model.currentAgentConnected || model.selectedChatIsArchived || model.selectedChat.map { model.isChangingChat($0.id) } == true)
                    }
                }.font(.ui(.caption))
                ScrollView {
                    VStack(spacing: .ui(6)) {
                        ForEach(queue) { message in
                            if let edit = model.queueEdit, edit.id == message.id {
                                QueueEditor(edit: edit, draft: edit.draft, focused: $editorFocused, height: $editorHeight,
                                            save: save, cancel: cancel)
                            } else {
                                row(message, reorders: queue.count > 1)
                            }
                        }
                    }
                }.frame(maxHeight: maxHeight(queue))
            }.frame(maxWidth: columnWidth).padding(.horizontal, .ui(24)).padding(.top, .ui(8))
        }
    }

    /// Room for every row up to a cap; an open editor adds its own height and raises the cap.
    private func maxHeight(_ queue: [QueuedMessage]) -> CGFloat {
        let rows = CGFloat(queue.count) * 78
        guard let id = model.queueEdit?.id, queue.contains(where: { $0.id == id }) else { return min(rows, 180) }
        return min(rows + max(0, min(editorHeight, 140) - 22), 300)
    }

    /// Why a message cannot be edited or moved now; nil when it can.
    private func lockReason(_ message: QueuedMessage) -> String? {
        if model.queuedMessageIsClaimed(message.id) {
            return L10n.text("Сообщение уже отправляется: его нельзя изменить или переместить.", "This message is already being sent; it can't be edited or moved.")
        }
        if !model.canChangeQueue(message.threadID) {
            return L10n.text("Чат в архиве или меняется: очередь сейчас не редактируется.", "The chat is archived or changing; the queue can't be edited now.")
        }
        return nil
    }

    private func row(_ message: QueuedMessage, reorders: Bool) -> some View {
        let locked = lockReason(message)
        let up = model.canMoveQueuedMessage(message.id, by: -1), down = model.canMoveQueuedMessage(message.id, by: 1)
        return HStack(alignment: .center, spacing: .ui(12)) {
            if reorders {
                Image(systemName: "line.3.horizontal").font(.ui(.caption)).foregroundStyle(.tertiary)
                    .opacity(locked == nil ? 1 : 0.35)
                    .help(locked ?? L10n.text("Перетащи, чтобы изменить порядок отправки", "Drag to change the sending order"))
                    .accessibilityHidden(true)
            }
            Text(message.text).font(.ui(.callout)).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading).help(message.text)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if locked == nil { model.beginQueueEdit(message.id) } }
            Button {
                Task { await model.sendQueuedMessageNow(message.id) }
            } label: {
                Label(model.priorityMessageID == message.id ? L10n.text("Останавливаю…", "Stopping…") : model.busy ? L10n.text("Прервать и отправить", "Interrupt and send") : L10n.text("Отправить сейчас", "Send now"), systemImage: "arrow.up")
            }.disabled(model.sending || !model.currentAgentConnected || model.priorityMessageID != nil || model.selectedChatIsArchived || model.selectedChat.map { model.isChangingChat($0.id) } == true)
            Button { model.beginQueueEdit(message.id) } label: {
                Label(L10n.text("Изменить", "Edit"), systemImage: "pencil").labelStyle(.iconOnly)
            }
            .buttonStyle(PointerButtonStyle(base: .plain))
            .help(locked ?? L10n.text("Изменить (или двойной щелчок по тексту)", "Edit (or double-click the text)"))
            .disabled(locked != nil)
            Button { model.removeQueuedMessage(message.id) } label: {
                Label(L10n.text("Убрать из очереди", "Remove from queue"), systemImage: "xmark").labelStyle(.iconOnly)
            }
            .buttonStyle(PointerButtonStyle(base: .plain)).help(L10n.text("Убрать из очереди", "Remove from queue"))
            .disabled(model.priorityMessageID == message.id)
        }
        .padding(.ui(10))
        .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DeskPalette.focusBorder, lineWidth: 1.5)
            .opacity(dropTarget == message.id && dragging != message.id ? 1 : 0).allowsHitTesting(false))
        .contextMenu {
            Button(L10n.text("Изменить", "Edit")) { model.beginQueueEdit(message.id) }.disabled(locked != nil)
            Button(L10n.text("Переместить выше", "Move up")) { move(message.id, by: -1) }.disabled(!up)
            Button(L10n.text("Переместить ниже", "Move down")) { move(message.id, by: 1) }.disabled(!down)
            Divider()
            Button(L10n.text("Убрать из очереди", "Remove from queue")) { model.removeQueuedMessage(message.id) }
                .disabled(model.priorityMessageID == message.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if up { Button(L10n.text("Переместить выше", "Move up")) { move(message.id, by: -1) } }
            if down { Button(L10n.text("Переместить ниже", "Move down")) { move(message.id, by: 1) } }
        }
        .modifier(QueueRowDrag(enabled: reorders && locked == nil, text: message.text) { dragging = message.id })
        .onDrop(of: [.plainText, .fileURL], delegate: QueueRowDrop(targetID: message.id, dragging: $dragging, dropTarget: $dropTarget, files: fileDrop) { source, target in
            withAnimation(DeskMotion.standard(reduceMotion)) { _ = model.moveQueuedMessage(source, onto: target) }
        })
    }

    private func move(_ id: String, by offset: Int) {
        withAnimation(DeskMotion.standard(reduceMotion)) { _ = model.moveQueuedMessage(id, by: offset) }
    }
    private func save() {
        model.saveQueueEdit()
        if model.queueEdit == nil { model.focusComposer() }
    }
    private func cancel() {
        model.cancelQueueEdit()
        model.focusComposer()
    }
}

/// The in-place editor of a queued message: the composer's own text view, so Return saves, Shift+Return adds a line,
/// dropped files insert their paths, and Esc cancels.
private struct QueueEditor: View {
    let edit: QueueEditSession
    @ObservedObject var draft: ComposerState
    @Binding var focused: Bool
    @Binding var height: CGFloat
    let save: () -> Void
    let cancel: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: .ui(10)) {
            MessageComposer(state: draft, focused: $focused, focusRequest: edit.focus,
                            onContentHeight: { height = $0 }, onCancel: cancel, onSubmit: save)
                .frame(height: min(max(height, 22), 140))
                .padding(.horizontal, .ui(8)).padding(.vertical, .ui(6))
                .background(DeskPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DeskPalette.focusBorder, lineWidth: 1.5).opacity(focused ? 1 : 0).allowsHitTesting(false))
                .accessibilityLabel(L10n.text("Текст сообщения в очереди", "Queued message text"))
            Button(action: save) {
                Label(L10n.text("Сохранить", "Save"), systemImage: "checkmark").labelStyle(.iconOnly)
            }
            .buttonStyle(PointerButtonStyle(base: .plain)).padding(.top, .ui(8))
            .help(L10n.text("Сохранить (Return). Shift+Return добавляет строку.", "Save (Return). Shift+Return adds a line."))
            .disabled(!draft.hasMessage)
            Button(action: cancel) {
                Label(L10n.text("Отменить", "Cancel"), systemImage: "xmark").labelStyle(.iconOnly)
            }
            .buttonStyle(PointerButtonStyle(base: .plain)).padding(.top, .ui(8))
            .help(L10n.text("Отменить правку (Esc)", "Cancel the edit (Esc)"))
        }
        .padding(.ui(10))
        .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Starts a reorder drag; the payload is the message text, so a drop elsewhere (the composer, another app) copies it.
private struct QueueRowDrag: ViewModifier {
    let enabled: Bool
    let text: String
    let start: () -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.onDrag { start(); return NSItemProvider(object: text as NSString) }
        } else {
            content
        }
    }
}

/// A row is a drop target for the queue's own drags (move onto its place) and passes file drops on to the chat's handler.
private struct QueueRowDrop: DropDelegate {
    let targetID: String
    @Binding var dragging: String?
    @Binding var dropTarget: String?
    let files: ChatFileDrop
    let move: (String, String) -> Void
    /// The queue's own drag carries text only; a file drag never reorders, even after an abandoned row drag.
    private func reorders(_ info: DropInfo) -> Bool { dragging != nil && !info.hasItemsConforming(to: [.fileURL]) }
    func validateDrop(info: DropInfo) -> Bool { reorders(info) || files.validateDrop(info: info) }
    func dropEntered(info: DropInfo) {
        if reorders(info) { dropTarget = targetID } else { files.dropEntered(info: info) }
    }
    func dropExited(info: DropInfo) {
        if reorders(info) { if dropTarget == targetID { dropTarget = nil } } else { files.dropExited(info: info) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        reorders(info) ? DropProposal(operation: .move) : files.dropUpdated(info: info)
    }
    func performDrop(info: DropInfo) -> Bool {
        guard reorders(info), let source = dragging else { return files.performDrop(info: info) }
        dragging = nil; dropTarget = nil
        if source != targetID { move(source, targetID) }
        return true
    }
}
