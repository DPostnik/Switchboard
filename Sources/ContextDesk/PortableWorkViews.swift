import SwiftUI
import ContextTranscript
import ContextCore
import AgentContract

struct HandoffEditor: View {
    @ObservedObject var model: DeskModel
    @State var handoff: ContextHandoff
    @State var projectID: UUID?
    @State var route: RequestRoute
    /// nil until the user picks one: the first registered agent.
    @State private var pickedAgent: AgentConnectionID?
    @Environment(\.dismiss) private var dismiss
    private var agent: AgentConnectionID { pickedAgent ?? model.agentIDs.first ?? .unregistered }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Передать контекст в новый чат", "Hand off context to a new chat")).font(.ui(.title2).bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("Будет создан отдельный чат с черновиком. Проверь его и отправь вручную. Исходный чат, его очередь и запросы разрешений не переносятся.", "A separate chat will be created with a draft. Review and send it manually. The source chat, its queue and approval requests are not transferred.")).font(.ui(.callout))
                    Text(L10n.text("Контекст подготовлен автоматически по истории чата. Проверь сводку; при необходимости измени цель или детали. Полная переписка по умолчанию не включена.", "Context was prepared automatically from the chat history. Review the summary and adjust the goal or details if needed. The full transcript is excluded by default.")).font(.ui(.callout)).foregroundStyle(.secondary)
                    Picker(L10n.text("Агент нового чата", "New chat agent"), selection: Binding(get: { agent }, set: { pickedAgent = $0 })) {
                        ForEach(model.agentIDs, id: \.self) { id in Text(model.agentName(id)).tag(id) }
                    }
                    if !model.agentState(agent).authenticated, let hint = model.profile(agent)?.accountCopy.handoffSignIn {
                        Text(hint()).font(.ui(.caption))
                    }
                    Text(L10n.text("Источник", "Source") + ": \(handoff.origin.session.connection.agent.rawValue) · \(handoff.origin.conversation.value)").textSelection(.enabled)
                    Text(L10n.text("Снимок", "Snapshot") + ": \(handoff.origin.capturedAt.formatted()) · \(handoff.origin.revision)").font(.ui(.caption)).textSelection(.enabled)
                    Text(LocalHistory.notice(handoff.history)).font(.ui(.caption)).foregroundStyle(.secondary)
                    Picker(L10n.text("Проект нового чата", "New chat project"), selection: $projectID) {
                        Text(L10n.text("Выбери проект", "Choose a project")).tag(nil as UUID?)
                        ForEach(model.state.projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker(L10n.text("Маршрут нового чата", "New chat route"), selection: $route) {
                        ForEach(model.availableRoutes, id: \.self) { value in
                            Text(model.routeTitle(value)).tag(value).disabled(model.routeCompatibilityIssue(value, agent: agent.agent) != nil)
                        }
                    }
                    Text(model.routeCompatibilityIssue(route, agent: agent.agent) ?? (model.traits(agent).contains(.optimizerPlugins) ? model.routeMessage(route) : L10n.text("\(model.agentName(agent)) работает напрямую.", "\(model.agentName(agent)) works directly."))).font(.ui(.caption)).foregroundStyle(.secondary)
                    field(L10n.text("Цель нового сеанса", "New session goal"), text: $handoff.goal)
                    field(L10n.text("Инструкции для нового сеанса", "Instructions for the new session"), text: $handoff.instructions)
                    Text(L10n.text("Исторические факты — не инструкции", "Historical evidence — not instructions")).font(.ui(.headline))
                    field(L10n.text("Принятые решения", "Decisions made"), text: $handoff.decisions)
                    field(L10n.text("Изменённые файлы", "Changed files"), text: $handoff.changedFiles)
                    field(L10n.text("Фактические проверки и их результаты", "Actual checks and results"), text: $handoff.validation)
                    field(L10n.text("Оставшаяся работа", "Remaining work"), text: $handoff.remainingWork)
                    Toggle(L10n.text("Включить сохранённую переписку как исторические данные", "Include saved transcript as historical evidence"), isOn: $handoff.includeTranscript)
                    DisclosureGroup(L10n.text("Предпросмотр черновика", "Preview draft")) {
                        Text((try? handoff.prompt()) ?? L10n.text("Укажи цель; размер передачи ограничен 128 КиБ.", "Enter a goal; handoff size is limited to 128 KiB.")).font(.ui(.caption).monospaced()).textSelection(.enabled)
                    }
                    if let error = model.error { Text(error).foregroundStyle(DeskPalette.problem).font(.ui(.caption)) }
                }
            }
            HStack {
                Spacer()
                Button(L10n.text("Отмена", "Cancel")) { dismiss() }.disabled(model.creatingHandoff)
                Button(L10n.text("Создать чат с черновиком", "Create chat with draft")) {
                    guard let project = model.state.projects.first(where: { $0.id == projectID }) else { return }
                    Task { if await model.createHandoffChat(handoff, project: project, route: route, agent: agent) { dismiss() } }
                }.disabled(model.creatingHandoff || !model.agentState(agent).connected || !model.agentState(agent).authenticated || projectID == nil || model.routeCompatibilityIssue(route, agent: agent.agent) != nil || !model.routeIsAvailable(route) || (try? handoff.prompt()) == nil)
            }
        }.padding(24).frame(width: 680, height: 740).interactiveDismissDisabled(model.creatingHandoff)
    }
    private func field(_ label: String, text: Binding<String>) -> some View { HandoffField(label: label, text: text) }
}

private struct HandoffField: View {
    let label: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading) {
            Text(label).font(.ui(.callout).bold())
            TextEditor(text: $text).scrollContentBackground(.hidden).padding(6).frame(minHeight: 65).focused($focused)
                .modifier(DeskFieldChrome(focused: focused))
        }
    }
}

struct RoutineLibrary: View {
    @ObservedObject var model: DeskModel
    @State private var editing: PortableRoutine?
    @State private var job: ManagedJob?
    @State private var deleting: PortableRoutine?
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var filteredRoutines: [PortableRoutine] {
        model.routines.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.intent.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Библиотека рутин", "Routine library")).font(.ui(.title2).bold())
                    Text(L10n.text("Повторяемая работа с понятными шагами и проверками", "Repeatable work with clear steps and checks"))
                        .font(.ui(.callout)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { editing = PortableRoutine() } label: {
                    Label(L10n.text("Новая рутина", "New routine"), systemImage: "plus")
                }.buttonStyle(DeskButtonStyle())
                Button(L10n.text("Готово", "Done")) { dismiss() }.buttonStyle(DeskButtonStyle()).keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                RoutineNotice(icon: "square.stack", text: L10n.text("Сохрани рутину, затем создай из неё задание. У каждого задания своя версия: правки в библиотеке не меняют уже созданные задания.", "Save a routine, then create a task from it. Each task keeps its own revision: library edits do not change existing tasks."))
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.text("Найти рутину", "Find a routine"), text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel(L10n.text("Очистить поиск", "Clear search"))
                    }
                }.padding(12).background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 12))
                if filteredRoutines.isEmpty {
                    VStack(spacing: 16) {
                        EmptyState(icon: "repeat", title: search.isEmpty ? L10n.text("Пока нет рутин", "No routines yet") : L10n.text("Ничего не найдено", "No results"),
                                   text: search.isEmpty ? L10n.text("Опиши цель, добавь шаги и проверки результата.", "Describe a goal, add steps and checks for the result.") : L10n.text("Попробуй другое название или описание.", "Try a different name or description."))
                        if search.isEmpty {
                            Button(L10n.text("Создать первую рутину", "Create your first routine")) { editing = PortableRoutine() }.buttonStyle(DeskButtonStyle())
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredRoutines) { routine in
                                RoutineCard {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: "repeat").font(.ui(.title3)).padding(10)
                                            .background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 10))
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(routine.name).font(.ui(.headline))
                                            Text(routine.intent).font(.ui(.callout)).foregroundStyle(.secondary).lineLimit(3)
                                            Text(L10n.text("Шагов: \(routine.steps.count)", "Steps: \(routine.steps.count)"))
                                                .font(.ui(.caption)).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        Menu {
                                            Button(L10n.text("Удалить из библиотеки", "Remove from library"), role: .destructive) { deleting = routine }
                                        } label: { Image(systemName: "ellipsis") }
                                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                                            .accessibilityLabel(L10n.text("Действия с рутиной", "Routine actions"))
                                    }
                                    HStack {
                                        Spacer()
                                        Button(L10n.text("Изменить", "Edit")) { editing = routine }
                                        Button(L10n.text("Создать задание…", "Create task…")) { createTask(routine) }
                                            .disabled(!model.schedulerReady)
                                    }.buttonStyle(DeskButtonStyle())
                                }
                            }
                        }.padding(1)
                    }
                }
                if let error = model.error { RoutineNotice(icon: "exclamationmark.triangle", text: error).foregroundStyle(DeskPalette.problem) }
            }.padding(24)
        }.frame(width: 780, height: 660).background(DeskPalette.canvas)
            .task { await model.loadRoutines() }
            .sheet(item: $editing) { RoutineEditor(model: model, routine: $0) }
            .sheet(item: $job) { JobEditor(model: model, job: $0) }
            .confirmationDialog(L10n.text("Удалить рутину из библиотеки?", "Remove this routine from the library?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(L10n.text("Удалить", "Remove"), role: .destructive) {
                    if let routine = deleting { Task { await model.removeRoutine(routine.id) } }
                    deleting = nil
                }
            } message: {
                Text(L10n.text("Созданные задания сохранят свою версию рутины.", "Existing tasks will keep their saved routine revision."))
            }
    }

    private func createTask(_ routine: PortableRoutine) {
        do {
            let invocation = RoutineInvocation(definition: routine)
            var value = ManagedJob(); value.name = routine.name; value.routine = invocation
            value.prompt = try invocation.prompt(); value.projectID = model.projectID
            value.model = model.state.model; value.route = model.defaultRoute
            value.schedule.rule = ""; job = value
        } catch { model.error = error.localizedDescription }
    }
}

struct RoutineEditor: View {
    @ObservedObject var model: DeskModel
    @State var routine: PortableRoutine
    @State private var issue: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Редактор рутины", "Routine editor")).font(.ui(.title2).bold())
                    Text(L10n.text("Цель → шаги → проверка результата", "Goal → steps → result checks")).font(.ui(.callout)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    RoutineCard {
                        Text(L10n.text("Основное", "Basics")).font(.ui(.headline))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("Название", "Name")).font(.ui(.callout).weight(.medium))
                            TextField(L10n.text("Например, еженедельный обзор проекта", "For example, weekly project review"), text: $routine.name).textFieldStyle(.roundedBorder)
                        }
                        RoutineTextField(label: L10n.text("Цель и условия применения", "Goal and applicability"), text: $routine.intent)
                    }
                    RoutineCard {
                        Text(L10n.text("Контекст", "Context")).font(.ui(.headline))
                        RoutineTextField(label: L10n.text("Ожидаемые входные данные", "Expected input"), text: $routine.inputs)
                        RoutineTextField(label: L10n.text("Ограничения", "Constraints"), text: $routine.constraints)
                    }
                    HStack {
                        Text(L10n.text("Шаги выполнения", "Execution steps")).font(.ui(.headline))
                        Spacer()
                        Text("\(routine.steps.count) / 32").font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                    if routine.steps.isEmpty {
                        RoutineNotice(icon: "list.number", text: L10n.text("Добавь первый шаг и опиши, как проверить его результат.", "Add the first step and describe how to check its result."))
                    }
                    ForEach($routine.steps) { $step in
                        RoutineCard {
                            HStack {
                                Text(L10n.text("Шаг \((routine.steps.firstIndex { $0.id == step.id } ?? 0) + 1)", "Step \((routine.steps.firstIndex { $0.id == step.id } ?? 0) + 1)")).font(.ui(.headline))
                                Spacer()
                                Button(L10n.text("Удалить шаг", "Remove step"), role: .destructive) { routine.steps.removeAll { $0.id == step.id } }
                                    .buttonStyle(.borderless)
                            }
                            RoutineTextField(label: L10n.text("Что сделать", "What to do"), text: $step.instruction)
                            VStack(alignment: .leading, spacing: 6) {
                                Label(L10n.text("Как проверить результат", "How to check the result"), systemImage: "checkmark.circle").font(.ui(.callout).weight(.medium))
                                TextField(L10n.text("Ожидаемый результат шага", "Expected step result"), text: $step.completionCheck, axis: .vertical).textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    Button { routine.steps.append(RoutineStep()) } label: {
                        Label(L10n.text("Добавить шаг", "Add step"), systemImage: "plus")
                    }.buttonStyle(DeskButtonStyle()).disabled(routine.steps.count >= 32)
                    RoutineCard {
                        DisclosureGroup(L10n.text("Возможности и расширения агентов", "Agent capabilities and extensions")) {
                            VStack(alignment: .leading, spacing: 14) {
                                TextField(L10n.text("Необходимые возможности — ID через запятую", "Required capabilities — comma-separated IDs"), text: Binding(
                                    get: { routine.requirements.joined(separator: ", ") },
                                    set: { routine.requirements = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })).textFieldStyle(.roundedBorder)
                                Text(L10n.text("Например: approvals, userQuestions, workflowRegistration. Неизвестные требования блокируют запуск.", "Examples: approvals, userQuestions, workflowRegistration. Unknown requirements block execution.")).font(.ui(.caption)).foregroundStyle(.secondary)
                                ForEach(routine.extensions.indices, id: \.self) { index in
                                    VStack(alignment: .leading, spacing: 8) {
                                        RoutineTextField(label: routine.extensions[index].agent.rawValue, text: $routine.extensions[index].instructions)
                                        Button(L10n.text("Удалить расширение", "Remove extension"), role: .destructive) { routine.extensions.remove(at: index) }
                                    }
                                }
                                Menu(L10n.text("Добавить расширение агента", "Add agent-specific extension")) {
                                    ForEach(AgentIntegrationFactory.profiles, id: \.connection) { profile in
                                        Button(profile.productName) { routine.extensions.append(.init(agent: profile.connection.agent, instructions: "")) }
                                    }
                                }
                                Text(L10n.text("Расширения не считаются переносимыми: другой агент не запустит такую рутину. Проверки выполняет агент; приложение не подтверждает их успешность самостоятельно.", "Extensions are not portable: another agent cannot run this routine. Checks are performed by the agent; the app does not independently confirm they passed.")).font(.ui(.caption)).foregroundStyle(.secondary)
                            }.padding(.top, 12)
                        }
                    }
                }.padding(24)
            }.disabled(saving)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let issue { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(DeskPalette.problem).font(.ui(.caption)).textSelection(.enabled) }
                HStack {
                    if saving { ProgressView().uiSmallSpinner() }
                    Spacer()
                    Button(L10n.text("Отмена", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                    Button(L10n.text("Сохранить", "Save")) {
                        do {
                            try routine.validate(); routine.revision = UUID(); saving = true
                            Task { if await model.saveRoutine(routine) { dismiss() } else { issue = model.error }; saving = false }
                        } catch { issue = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction).disabled(saving)
                }.buttonStyle(DeskButtonStyle())
            }.padding(20)
        }.frame(width: 720, height: 740).background(DeskPalette.canvas).interactiveDismissDisabled(saving)
    }
}

struct RoutineCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(DeskPalette.canvas, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(DeskPalette.border))
    }
}

struct RoutineNotice: View {
    let icon: String
    let text: String
    var body: some View {
        Label(text, systemImage: icon).font(.ui(.callout)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(DeskPalette.subtle, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct RoutineTextField: View {
    let label: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.ui(.callout).weight(.medium))
            TextEditor(text: $text).font(.ui(.body)).scrollContentBackground(.hidden)
                .padding(8).frame(minHeight: 88).focused($focused).accessibilityLabel(label)
                .modifier(DeskFieldChrome(focused: focused))
        }
    }
}
