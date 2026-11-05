import SwiftUI
import ContextCore
import AgentContract
import ContextTranscript

/// Compact line above the composer: what the chat's sub-agents and background commands are doing, with a live preview on click.
struct SubagentsBar: View {
    @ObservedObject var model: DeskModel
    let chatID: String
    @State private var showing = false

    var body: some View {
        let agents = model.subagents[chatID] ?? []
        let tasks = model.backgroundTasks[chatID] ?? []
        let stalled = model.stalledSubagents[chatID] ?? []
        let waiting = Self.waiting(tasks)
        if !agents.isEmpty || !tasks.isEmpty {
            let summary = Self.summary(agents, stalled: stalled, tasks: tasks)
            Button { showing.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: agents.isEmpty ? "terminal" : "person.2").foregroundStyle(.secondary)
                    Text(summary).foregroundStyle(.secondary)
                    ForEach(agents.prefix(4)) { agent in
                        chip(agent.title) { SubagentStatusIcon(status: agent.status, stalled: stalled.contains(agent.id), waiting: waiting.contains(agent.id)) }
                    }
                    ForEach(tasks.prefix(max(0, 4 - agents.count))) { task in chip(task.title) { SubagentStatusIcon(status: task.status) } }
                    if agents.count + tasks.count > 4 { Text("+\(agents.count + tasks.count - 4)").foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    Text(L10n.text("Показать", "Show")).fontWeight(.medium).foregroundStyle(DeskPalette.accentDeep)
                }.font(.ui(.callout)).contentShape(Rectangle())
            }
            .buttonStyle(PointerButtonStyle(base: .plain))
            .help(L10n.text("Посмотреть, чем заняты подагенты и фоновые задачи", "See what the sub-agents and background tasks are doing"))
            .accessibilityLabel(summary)
            .popover(isPresented: $showing, arrowEdge: .top) { SubagentsPanel(model: model, chatID: chatID) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 6)
        }
    }

    private func chip(_ title: String, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: 4) {
            icon()
            Text(title).lineLimit(1).truncationMode(.tail)
        }.padding(.horizontal, 7).padding(.vertical, 3).frame(maxWidth: 180)
            .background(DeskPalette.subtle, in: Capsule())
    }

    /// Sub-agents that ended their turn but wait for a background command they started; they resume when it finishes.
    static func waiting(_ tasks: [AgentBackgroundTask]) -> Set<String> {
        Set(tasks.filter { $0.status == .running }.compactMap(\.parentID))
    }

    static func summary(_ agents: [AgentSubagent], stalled: Set<String> = [], tasks: [AgentBackgroundTask] = []) -> String {
        var groups: [String] = []
        if !agents.isEmpty {
            let waiting = Self.waiting(tasks)
            let running = agents.filter { $0.status == .running }.count
            let silent = agents.filter { $0.status == .running && stalled.contains($0.id) }.count
            let waits = agents.filter { $0.status != .running && waiting.contains($0.id) }.count
            let done = agents.filter { $0.status == .completed && !waiting.contains($0.id) }.count
            let failed = agents.count - running - waits - done
            var parts = [L10n.text("Подагенты", "Sub-agents") + ":"]
            if running > 0 { parts.append(L10n.text("работают \(running)", "\(running) running")) }
            if silent > 0 { parts.append(L10n.text("без ответа \(silent)", "\(silent) not responding")) }
            if waits > 0 { parts.append(L10n.text("ждут фоновые задачи \(waits)", "\(waits) waiting for background tasks")) }
            if done > 0 { parts.append(L10n.text("готово \(done)", "\(done) done")) }
            if failed > 0 { parts.append(L10n.text("прервано \(failed)", "\(failed) stopped")) }
            groups.append(parts.joined(separator: " "))
        }
        if !tasks.isEmpty {
            let running = tasks.filter { $0.status == .running }.count
            let done = tasks.filter { $0.status == .completed }.count
            let failed = tasks.count - running - done
            var parts = [L10n.text("Фоновые задачи", "Background tasks") + ":"]
            if running > 0 { parts.append(L10n.text("работают \(running)", "\(running) running")) }
            if done > 0 { parts.append(L10n.text("готово \(done)", "\(done) done")) }
            if failed > 0 { parts.append(L10n.text("прервано \(failed)", "\(failed) stopped")) }
            groups.append(parts.joined(separator: " "))
        }
        return groups.joined(separator: " · ")
    }
}

struct SubagentStatusIcon: View {
    let status: AgentSubagent.Status
    var stalled = false
    /// An ended sub-agent that waits for its own background commands.
    var waiting = false
    var body: some View {
        switch status {
        case _ where waiting && status != .running: Image(systemName: "hourglass").foregroundStyle(.secondary)
        case .running where stalled: Image(systemName: "exclamationmark.circle").foregroundStyle(DeskPalette.attention)
        case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(DeskPalette.accent)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DeskPalette.attention)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
    /// Shown for a running sub-agent that has been silent longer than `SubagentWatch` allows.
    static func silentLine(_ agent: AgentSubagent) -> String {
        let time = agent.lastActivityAt.formatted(date: .omitted, time: .shortened)
        return L10n.text("Нет ответа с \(time)", "No response since \(time)")
    }
    static func title(_ status: AgentSubagent.Status, waiting: Bool = false) -> String {
        if waiting && status != .running { return L10n.text("Ждёт фоновые задачи", "Waiting for background tasks") }
        return switch status {
        case .running: L10n.text("Работает", "Running")
        case .completed: L10n.text("Готово", "Done")
        case .failed: L10n.text("Ошибка", "Failed")
        case .stopped: L10n.text("Остановлен", "Stopped")
        }
    }
}

/// Live list of sub-agents and background commands with the selected one's latest steps or output. Everything shown is
/// engine/tool output.
struct SubagentsPanel: View {
    @ObservedObject var model: DeskModel
    let chatID: String
    @State private var selection: String?

    var body: some View {
        let agents = model.subagents[chatID] ?? []
        let tasks = model.backgroundTasks[chatID] ?? []
        let stalled = model.stalledSubagents[chatID] ?? []
        let waiting = SubagentsBar.waiting(tasks)
        let selected = selection.flatMap { id in agents.contains { $0.id == id } || tasks.contains { $0.id == id } ? id : nil }
            ?? agents.first { $0.status == .running }?.id ?? tasks.first { $0.status == .running }?.id ?? agents.first?.id ?? tasks.first?.id
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !agents.isEmpty && !tasks.isEmpty { header(L10n.text("Подагенты", "Sub-agents")) }
                    ForEach(agents) { agent in
                        row(agent.id, selected: selected) {
                            SubagentRow(agent: agent, stalled: stalled.contains(agent.id), waiting: waiting.contains(agent.id))
                        }
                    }
                    if !tasks.isEmpty {
                        header(L10n.text("Фоновые задачи", "Background tasks"))
                        ForEach(tasks) { task in row(task.id, selected: selected) { BackgroundTaskRow(task: task) } }
                    }
                }.padding(8)
            }.frame(width: 250).background(DeskPalette.sidebar)
            Divider()
            if let agent = agents.first(where: { $0.id == selected }) {
                SubagentDetail(model: model, chatID: chatID, agent: agent, stalled: stalled.contains(agent.id),
                               waiting: tasks.filter { $0.parentID == agent.id && $0.status == .running }).id(agent.id)
            } else if let task = tasks.first(where: { $0.id == selected }) {
                BackgroundTaskDetail(model: model, chatID: chatID, task: task,
                                     parent: task.parentID.flatMap { id in agents.first { $0.id == id }?.title }).id(task.id)
            } else {
                Text(L10n.text("Подагентов и фоновых задач нет", "No sub-agents or background tasks")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 780, height: 540)
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 6)
    }
    private func row(_ id: String, selected: String?, @ViewBuilder label: () -> some View) -> some View {
        Button { selection = id } label: { label() }
            .buttonStyle(PointerButtonStyle(base: .plain))
            .background(id == selected ? DeskPalette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SubagentRow: View {
    let agent: AgentSubagent
    let stalled: Bool
    let waiting: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SubagentStatusIcon(status: agent.status, stalled: stalled, waiting: waiting).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.title).font(.ui(.callout).weight(.medium)).lineLimit(2)
                if stalled {
                    Text(SubagentStatusIcon.silentLine(agent)).font(.ui(.caption)).foregroundStyle(DeskPalette.attention).lineLimit(2)
                } else {
                    Text(agent.activity ?? SubagentStatusIcon.title(agent.status, waiting: waiting)).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(2)
                }
                SubagentElapsed(agent: agent).font(.ui(.caption2)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

private struct SubagentElapsed: View {
    let agent: AgentSubagent
    var body: some View {
        var extra: [String] = []
        if let tools = agent.toolUses { extra.append(L10n.text("инструментов: \(tools)", "tools: \(tools)")) }
        if let tokens = agent.tokens { extra.append(L10n.text("токенов: \(tokens.formatted())", "tokens: \(tokens.formatted())")) }
        if agent.background { extra.append(L10n.text("в фоне", "background")) }
        return ElapsedLine(start: agent.startedAt, end: agent.endedAt, extra: extra)
    }
}

/// Run time, ticking while there is no end, followed by `extra`.
private struct ElapsedLine: View {
    let start: Date
    let end: Date?
    var extra: [String] = []
    var body: some View {
        // A finished run's time is fixed, so only a running one needs the clock.
        if let end {
            Text(line(until: end))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in Text(line(until: context.date)) }
        }
    }
    private func line(until end: Date) -> String {
        let seconds = Int(max(0, end.timeIntervalSince(start)))
        let time = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return ([time] + extra).joined(separator: " · ")
    }
}

private struct BackgroundTaskRow: View {
    let task: AgentBackgroundTask
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SubagentStatusIcon(status: task.status).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.ui(.callout).weight(.medium)).lineLimit(2)
                if let command = task.command, command != task.title {
                    Text(command).font(.ui(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(task.activity ?? SubagentStatusIcon.title(task.status)).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(2)
                }
                ElapsedLine(start: task.startedAt, end: task.endedAt).font(.ui(.caption2)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

/// One background command: its command line, state and the end of its output, read again every few seconds while it runs.
private struct BackgroundTaskDetail: View {
    @ObservedObject var model: DeskModel
    let chatID: String
    let task: AgentBackgroundTask
    /// Title of the sub-agent that started it.
    let parent: String?
    @State private var output: AgentTaskOutput?
    @State private var outputProblem: String?
    static let pollInterval: Duration = .seconds(2)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SubagentStatusIcon(status: task.status)
                Text(task.title).font(.ui(.headline)).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 0)
                Text(SubagentStatusIcon.title(task.status)).font(.ui(.caption)).foregroundStyle(.secondary)
                if task.status == .running {
                    let stopping = model.stoppingTasks.contains(DeskModel.stopKey(threadID: chatID, task: task.id))
                    Button { Task { await model.stopBackgroundTasks(threadID: chatID, task: task.id) } } label: {
                        Label(L10n.text("Остановить", "Stop"), systemImage: "stop.circle")
                    }
                    .controlSize(.small).disabled(stopping)
                    .help(L10n.text("Остановить только эту задачу. Агент продолжит работу и узнает об остановке.",
                                    "Stop only this task. The agent keeps working and learns that it was stopped."))
                }
            }
            HStack(spacing: 6) {
                Text(Self.kindTitle(task.kind))
                ElapsedLine(start: task.startedAt, end: task.endedAt)
                if let parent { Text(L10n.text("запустил подагент «\(parent)»", "started by sub-agent \"\(parent)\"")).lineLimit(1) }
            }.font(.ui(.caption)).foregroundStyle(.secondary)
            if let command = task.command {
                ScrollView {
                    Text(command).font(.ui(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 70).padding(6).background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 6))
            }
            if let activity = task.activity { Label(activity, systemImage: "ellipsis.circle").font(.ui(.callout)).lineLimit(2) }
            if let report = task.report, task.status != .running {
                Text(report).font(.ui(.callout)).textSelection(.enabled).lineLimit(4).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading).background(DeskPalette.accentWash, in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            if task.hasOutput { outputView } else {
                Text(L10n.text("Claude не отдаёт вывод задач этого вида.", "Claude does not return the output of this kind of task."))
                    .font(.ui(.callout)).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Restarts when the task ends, for one last read.
        .task(id: task.status) { await poll() }
    }

    @ViewBuilder private var outputView: some View {
        HStack(spacing: 6) {
            Text(L10n.text("Вывод", "Output")).font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
            if let output, output.truncated {
                let size = ByteCountFormatter.string(fromByteCount: Int64(output.totalBytes), countStyle: .file)
                Text(L10n.text("последние 8 КБ из \(size)", "last 8 KB of \(size)")).font(.ui(.caption)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if task.status == .running { Text(L10n.text("обновляется", "updating")).font(.ui(.caption2)).foregroundStyle(.tertiary) }
        }
        if let outputProblem { Text(outputProblem).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(3) }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let output {
                        Text(output.text.isEmpty ? L10n.text("(команда пока ничего не вывела)", "(the command has printed nothing yet)") : output.text)
                            .font(.ui(.caption, design: .monospaced)).foregroundStyle(output.text.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else if outputProblem == nil {
                        ProgressView().controlSize(.small)
                    }
                    Color.clear.frame(height: 1).id("end")
                }.padding(8)
            }
            .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: output?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func poll() async {
        guard task.hasOutput else { return }
        while !Task.isCancelled {
            do {
                let next = try await model.taskOutput(threadID: chatID, task: task.id)
                if output != next { output = next }
                outputProblem = nil
            } catch {
                guard !Task.isCancelled else { return }
                // Once the CLI is gone its output went with it; what was read before stays on screen.
                outputProblem = task.status == .running ? error.localizedDescription
                    : L10n.text("Вывод больше недоступен: процесс Claude завершён.", "The output is no longer available: the Claude process has ended.")
            }
            guard task.status == .running else { return }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    static func kindTitle(_ kind: AgentBackgroundTask.Kind) -> String {
        switch kind {
        case .shell: L10n.text("Команда", "Command")
        case .monitor: L10n.text("Наблюдение", "Monitor")
        case .workflow: L10n.text("Сценарий", "Workflow")
        case .mcp: L10n.text("Задача MCP", "MCP task")
        case .other: L10n.text("Задача", "Task")
        }
    }
}

private struct SubagentDetail: View {
    @ObservedObject var model: DeskModel
    let chatID: String
    let agent: AgentSubagent
    let stalled: Bool
    /// Its own background commands that still run; it resumes when they finish.
    var waiting: [AgentBackgroundTask] = []
    @State private var showingPrompt = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The list follows new steps only while the user is at (or near) its end.
    @State private var followsEnd = true
    @State private var viewportHeight: CGFloat = 0
    /// Content already measured; a geometry change from newer content is not a user scroll.
    @State private var seenSteps = 0
    @State private var seenStatus: AgentSubagent.Status?
    private static let stepsSpace = "subagentSteps"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SubagentStatusIcon(status: agent.status, stalled: stalled, waiting: !waiting.isEmpty)
                Text(agent.title).font(.ui(.headline)).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 0)
                Text(SubagentStatusIcon.title(agent.status, waiting: !waiting.isEmpty)).font(.ui(.caption)).foregroundStyle(.secondary)
                if agent.status == .running {
                    let stopping = model.stoppingTasks.contains(DeskModel.stopKey(threadID: chatID, task: agent.id))
                    Button { Task { await model.stopBackgroundTasks(threadID: chatID, task: agent.id) } } label: {
                        Label(L10n.text("Остановить", "Stop"), systemImage: "stop.circle")
                    }
                    .controlSize(.small).disabled(stopping)
                    .help(L10n.text("Остановить только этого подагента. Основной агент продолжит работу.",
                                    "Stop only this sub-agent. The main agent keeps working."))
                }
            }
            HStack(spacing: 6) {
                if let type = agent.type { Text(type) }
                SubagentElapsed(agent: agent)
            }.font(.ui(.caption)).foregroundStyle(.secondary)
            if stalled {
                Label(SubagentStatusIcon.silentLine(agent) + ". " + L10n.text(
                    "Подагент мог зависнуть. Основной агент получит сообщение об этом, когда освободится.",
                    "The sub-agent may be stuck. The main agent gets a message about it once it is free."),
                      systemImage: "exclamationmark.circle")
                    .font(.ui(.callout)).foregroundStyle(DeskPalette.attention).lineLimit(3)
            }
            if let activity = agent.activity {
                Label(activity, systemImage: "ellipsis.circle").font(.ui(.callout)).lineLimit(2)
            }
            if agent.status != .running, !waiting.isEmpty {
                Label(L10n.text("Ждёт свои фоновые задачи (\(waiting.count)) и продолжит работу, когда они закончатся. Они в списке слева.",
                                "Waits for its background tasks (\(waiting.count)) and resumes when they finish. They are in the list on the left."),
                      systemImage: "hourglass")
                    .font(.ui(.callout)).foregroundStyle(.secondary).lineLimit(3)
            }
            DisclosureGroup(L10n.text("Задание", "Task"), isExpanded: $showingPrompt) {
                ScrollView { Text(agent.prompt).font(.ui(.caption)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 120)
            }.font(.ui(.callout))
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if agent.droppedSteps > 0 {
                            Text(L10n.text("Ранние шаги скрыты: \(agent.droppedSteps)", "Earlier steps hidden: \(agent.droppedSteps)"))
                                .font(.ui(.caption)).foregroundStyle(.secondary)
                        }
                        if agent.steps.isEmpty && agent.report == nil {
                            Text(L10n.text("Шагов пока нет.", "No steps yet.")).font(.ui(.callout)).foregroundStyle(.secondary)
                        }
                        ForEach(agent.steps) { step in SubagentStepView(step: step).id(step.id) }
                        if let report = agent.report, agent.status != .running {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text("Итоговый отчёт", "Final report")).font(.ui(.caption).weight(.semibold)).foregroundStyle(.secondary)
                                Text(report).font(.ui(.callout)).textSelection(.enabled)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(DeskPalette.accentWash, in: RoundedRectangle(cornerRadius: 8)).id("report")
                        }
                        Color.clear.frame(height: 1).id("end")
                            .background(GeometryReader { end in
                                Color.clear.onChange(of: end.frame(in: .named(Self.stepsSpace)).minY) { _, y in
                                    guard agent.steps.count == seenSteps, agent.status == seenStatus else { return }
                                    followsEnd = y - viewportHeight < 80
                                }
                            })
                    }.padding(.vertical, 4)
                }
                .coordinateSpace(.named(Self.stepsSpace))
                .background(GeometryReader { box in
                    Color.clear.onAppear { viewportHeight = box.size.height }
                        .onChange(of: box.size.height) { _, height in viewportHeight = height }
                })
                .onAppear {
                    seenSteps = agent.steps.count; seenStatus = agent.status
                    proxy.scrollTo("end", anchor: .bottom)
                }
                .onChange(of: agent.steps.count) { _, count in
                    if followsEnd { scrollToEnd(proxy) }
                    seenSteps = count
                }
                .onChange(of: agent.status) { _, status in
                    if followsEnd { scrollToEnd(proxy) }
                    seenStatus = status
                }
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo("end", anchor: .bottom) }
    }
}

private struct SubagentStepView: View {
    let step: AgentSubagent.Step
    var body: some View {
        switch step.kind {
        case .text:
            Text(step.text).font(.ui(.callout)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label { Text(step.text).font(.ui(.caption, design: .monospaced)).lineLimit(3).textSelection(.enabled) }
                icon: { Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary) }
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 6))
        case .result:
            Text(step.text.isEmpty ? L10n.text("(пустой результат)", "(empty result)") : step.text)
                .font(.ui(.caption2, design: .monospaced)).foregroundStyle(step.isError ? DeskPalette.problem : .secondary)
                .lineLimit(6).textSelection(.enabled).padding(.leading, 22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
