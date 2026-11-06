import SwiftUI
import ContextCore
import ContextTranscript

/// Toolbar button of the open chat's job: what the agent works towards ("done when"), how long, and what it does now.
struct ChatJobButton: View {
    @ObservedObject var model: DeskModel
    let chatID: String
    @State private var showing = false

    var body: some View {
        let job = model.state.chats.first { $0.id == chatID }?.job
        let active = job?.isActive == true
        Button { showing.toggle() } label: {
            Label(L10n.text("Задача", "Job"), systemImage: active ? "flag.fill" : "flag")
        }
        .pointingHandCursor()
        .help(active ? L10n.text("Задача чата: готово, когда ", "Chat job: done when ") + (job?.doneWhen ?? "")
                     : L10n.text("Задать задачу чата и условие её завершения", "Set the chat's job and its done-when criterion"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ChatJobPanel(model: model, chatID: chatID, transcript: model.transcript)
        }
    }
}

struct ChatJobPanel: View {
    @ObservedObject var model: DeskModel
    let chatID: String
    /// The selected chat's transcript, for the running tool call; observed only while the panel is open.
    @ObservedObject var transcript: TranscriptPresentation
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let job = model.state.chats.first { $0.id == chatID }?.job
        VStack(alignment: .leading, spacing: 14) {
            if let job, !editing {
                if job.isActive { active(job) } else { closed(job) }
            } else {
                editor(job)
            }
        }
        .padding(18).frame(width: 360, alignment: .leading)
    }

    // MARK: Open job

    @ViewBuilder private func active(_ job: ChatJob) -> some View {
        let busy = model.isBusy(threadID: chatID)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 7) {
                Circle().fill(busy ? DeskPalette.accent : DeskPalette.muted).frame(width: 8, height: 8)
                Text(L10n.text("Задача открыта \(ChatJob.duration(job.elapsed(now: context.date)))",
                               "Job open for \(ChatJob.duration(job.elapsed(now: context.date)))"))
                    .font(.ui(.callout).weight(.semibold)).monospacedDigit()
            }
        }
        section(L10n.text("Сейчас", "Now")) { now(busy: busy) }
        section(L10n.text("Готово, когда", "Done when")) {
            HStack(alignment: .top, spacing: 8) {
                Text(job.doneWhen).font(.ui(.body)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { draft = job.doneWhen; editing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(PointerButtonStyle(base: .plain)).foregroundStyle(.secondary)
                    .help(L10n.text("Изменить условие", "Edit the criterion"))
                    .accessibilityLabel(L10n.text("Изменить условие", "Edit the criterion"))
            }
            Text(job.pendingNote == nil
                 ? L10n.text("Агент получил это условие.", "The agent has this criterion.")
                 : L10n.text("Агент получит условие со следующим сообщением.", "The agent receives the criterion with the next message."))
                .font(.ui(.caption)).foregroundStyle(.secondary)
        }
        HStack(spacing: 8) {
            Button(L10n.text("Готово", "Done")) { Task { await model.closeChatJob(chatID, done: true) } }
                .buttonStyle(DeskButtonStyle(kind: .primary))
                .help(L10n.text("Отметить задачу выполненной", "Mark the job as done"))
            Button(L10n.text("Отменить задачу", "Cancel job")) { Task { await model.closeChatJob(chatID, done: false) } }
                .buttonStyle(DeskButtonStyle())
                .help(busy ? L10n.text("Закрыть задачу и остановить текущий ход агента", "Close the job and stop the agent's current turn")
                           : L10n.text("Закрыть задачу без выполнения", "Close the job as not done"))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func now(busy: Bool) -> some View {
        if busy {
            let run = model.runActivity(threadID: chatID)
            let tool = model.chatID == chatID ? TranscriptScrollView.currentActivityLine(transcript.items) : nil
            Text(tool ?? run.status ?? L10n.text("Агент работает", "The agent is working"))
                .font(.ui(.body)).lineLimit(2).truncationMode(.tail)
            if let since = run.since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(L10n.text("Ход идёт \(ChatJob.duration(context.date.timeIntervalSince(since)))",
                                   "Turn running for \(ChatJob.duration(context.date.timeIntervalSince(since)))"))
                        .font(.ui(.caption)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } else {
            Text(L10n.text("Агент ждёт вашего сообщения", "The agent is waiting for your message"))
                .font(.ui(.body)).foregroundStyle(.secondary)
        }
    }

    // MARK: Closed job

    @ViewBuilder private func closed(_ job: ChatJob) -> some View {
        let done = job.status == .done
        let duration = ChatJob.duration(job.elapsed())
        HStack(spacing: 7) {
            Image(systemName: done ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(done ? DeskPalette.accent : .secondary)
            Text(done ? L10n.text("Выполнена за \(duration)", "Done in \(duration)")
                      : L10n.text("Отменена через \(duration)", "Cancelled after \(duration)"))
                .font(.ui(.callout).weight(.semibold))
        }
        section(L10n.text("Готово, когда", "Done when")) {
            Text(job.doneWhen).font(.ui(.body)).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if job.pendingNote != nil {
                Text(L10n.text("Агент узнает о закрытии задачи со следующим сообщением.", "The agent learns that the job is closed with the next message."))
                    .font(.ui(.caption)).foregroundStyle(.secondary)
            }
        }
        Button(L10n.text("Новая задача", "New job")) { draft = ""; editing = true }
            .buttonStyle(DeskButtonStyle(kind: .primary))
    }

    // MARK: Editor

    @ViewBuilder private func editor(_ job: ChatJob?) -> some View {
        let editsOpenJob = job?.isActive == true
        Text(editsOpenJob ? L10n.text("Изменить условие", "Edit the criterion") : L10n.text("Новая задача", "New job"))
            .font(.ui(.callout).weight(.semibold))
        ChatJobCriterionField(text: $draft)
        Text(L10n.text("Агент получит условие со следующим сообщением и будет работать, пока оно не выполнено.",
                       "The agent receives the criterion with your next message and works until it is met."))
            .font(.ui(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
            Button(editsOpenJob ? L10n.text("Сохранить", "Save") : L10n.text("Начать задачу", "Start job")) {
                if model.setChatJob(chatID, doneWhen: draft) { editing = false }
            }
            .buttonStyle(DeskButtonStyle(kind: .primary))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(ChatJob.criterion(draft) == nil)
            if job != nil {
                Button(L10n.text("Отмена", "Cancel")) { editing = false }.buttonStyle(DeskButtonStyle(kind: .text))
            }
            Spacer(minLength: 0)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.ui(.caption2).weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct ChatJobCriterionField: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        let label = L10n.text("Готово, когда", "Done when")
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.ui(.callout).weight(.medium))
            TextEditor(text: $text).font(.ui(.body)).scrollContentBackground(.hidden)
                .padding(8).frame(height: 96).focused($focused).accessibilityLabel(label)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L10n.text("Например: тесты проходят, приложение собрано, изменения закоммичены и отправлены.",
                                       "For example: tests pass, the app builds, the changes are committed and pushed."))
                            .font(.ui(.body)).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .modifier(DeskFieldChrome(focused: focused))
                .onAppear { focused = true }
        }
    }
}
