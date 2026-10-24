import SwiftUI
import ContextCore
import AgentContract
import ContextTranscript

/// Compact line above the composer: what the chat's sub-agents are doing, with a live preview on click.
struct SubagentsBar: View {
    @ObservedObject var model: DeskModel
    let chatID: String
    @State private var showing = false

    var body: some View {
        let agents = model.subagents[chatID] ?? []
        if !agents.isEmpty {
            Button { showing.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.2").foregroundStyle(.secondary)
                    Text(Self.summary(agents)).foregroundStyle(.secondary)
                    ForEach(agents.prefix(4)) { agent in
                        HStack(spacing: 4) {
                            SubagentStatusIcon(status: agent.status)
                            Text(agent.title).lineLimit(1).truncationMode(.tail)
                        }.padding(.horizontal, 7).padding(.vertical, 3).frame(maxWidth: 180)
                            .background(DeskPalette.subtle, in: Capsule())
                    }
                    if agents.count > 4 { Text("+\(agents.count - 4)").foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    Text(L10n.text("Показать", "Show")).foregroundStyle(.blue)
                }.font(.ui(.callout)).contentShape(Rectangle())
            }
            .buttonStyle(PointerButtonStyle(base: .plain))
            .help(L10n.text("Посмотреть, чем заняты подагенты", "See what the sub-agents are doing"))
            .accessibilityLabel(Self.summary(agents))
            .popover(isPresented: $showing, arrowEdge: .top) { SubagentsPanel(model: model, chatID: chatID) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 6)
        }
    }

    static func summary(_ agents: [AgentSubagent]) -> String {
        let running = agents.filter { $0.status == .running }.count
        let done = agents.filter { $0.status == .completed }.count
        let failed = agents.count - running - done
        var parts = [L10n.text("Подагенты", "Sub-agents") + ":"]
        if running > 0 { parts.append(L10n.text("работают \(running)", "\(running) running")) }
        if done > 0 { parts.append(L10n.text("готово \(done)", "\(done) done")) }
        if failed > 0 { parts.append(L10n.text("прервано \(failed)", "\(failed) stopped")) }
        return parts.joined(separator: " ")
    }
}

struct SubagentStatusIcon: View {
    let status: AgentSubagent.Status
    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
    static func title(_ status: AgentSubagent.Status) -> String {
        switch status {
        case .running: L10n.text("Работает", "Running")
        case .completed: L10n.text("Готово", "Done")
        case .failed: L10n.text("Ошибка", "Failed")
        case .stopped: L10n.text("Остановлен", "Stopped")
        }
    }
}

/// Live list of sub-agents with the selected one's latest steps. Everything shown is engine/tool output.
struct SubagentsPanel: View {
    @ObservedObject var model: DeskModel
    let chatID: String
    @State private var selection: String?

    var body: some View {
        let agents = model.subagents[chatID] ?? []
        let selected = agents.first { $0.id == selection } ?? agents.first { $0.status == .running } ?? agents.first
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(agents) { agent in
                        Button { selection = agent.id } label: { SubagentRow(agent: agent) }
                            .buttonStyle(PointerButtonStyle(base: .plain))
                            .background(agent.id == selected?.id ? DeskPalette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(8)
            }.frame(width: 250).background(DeskPalette.sidebar)
            Divider()
            if let selected { SubagentDetail(model: model, chatID: chatID, agent: selected).id(selected.id) }
            else {
                Text(L10n.text("Подагентов нет", "No sub-agents")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 780, height: 540)
    }
}

private struct SubagentRow: View {
    let agent: AgentSubagent
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SubagentStatusIcon(status: agent.status).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.title).font(.ui(.callout).weight(.medium)).lineLimit(2)
                Text(agent.activity ?? SubagentStatusIcon.title(agent.status)).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(2)
                SubagentElapsed(agent: agent).font(.ui(.caption2)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

private struct SubagentElapsed: View {
    let agent: AgentSubagent
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(max(0, (agent.endedAt ?? context.date).timeIntervalSince(agent.startedAt)))
            var parts = [String(format: "%d:%02d", seconds / 60, seconds % 60)]
            if let tools = agent.toolUses { parts.append(L10n.text("инструментов: \(tools)", "tools: \(tools)")) }
            if let tokens = agent.tokens { parts.append(L10n.text("токенов: \(tokens.formatted())", "tokens: \(tokens.formatted())")) }
            if agent.background { parts.append(L10n.text("в фоне", "background")) }
            return Text(parts.joined(separator: " · "))
        }
    }
}

private struct SubagentDetail: View {
    @ObservedObject var model: DeskModel
    let chatID: String
    let agent: AgentSubagent
    @State private var showingPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SubagentStatusIcon(status: agent.status)
                Text(agent.title).font(.ui(.headline)).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 0)
                Text(SubagentStatusIcon.title(agent.status)).font(.ui(.caption)).foregroundStyle(.secondary)
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
            if let activity = agent.activity {
                Label(activity, systemImage: "ellipsis.circle").font(.ui(.callout)).lineLimit(2)
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
                                .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 8)).id("report")
                        }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(.vertical, 4)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: agent.steps.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: agent.status) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                .font(.ui(.caption2, design: .monospaced)).foregroundStyle(step.isError ? .orange : .secondary)
                .lineLimit(6).textSelection(.enabled).padding(.leading, 22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
