import SwiftUI
import ContextTranscript
import ContextCore

struct JobsView: View {
    @ObservedObject var model: DeskModel
    @State private var selection: String?
    @State private var editing: ManagedJob?
    @State private var deleting: ManagedJob?
    @State private var showingRoutines = false
    @State private var search = ""
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { pageTitle.fixedSize(); Spacer(); pageActions.fixedSize() }
                VStack(alignment: .leading, spacing: 16) { pageTitle; pageActions }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(DeskButtonStyle()).padding(24)
            Text(model.schedulerReady
                 ? L10n.text("Запуски работают, пока Switchboard открыт и Mac не спит. После простоя выполняется одно пропущенное задание. До трёх запусков одновременно.", "Tasks run while Switchboard is open and your Mac is awake. After downtime, each due task runs once. Up to three runs at a time.")
                 : L10n.text("Планировщик недоступен. Проверь сообщение об ошибке и перезапусти приложение.", "The scheduler is unavailable. Check the error and restart the app."))
                .font(.ui(.caption)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.text("Найти задание", "Find a task"), text: $search).textFieldStyle(.plain)
                }.padding(12).background(DeskPalette.canvas, in: RoundedRectangle(cornerRadius: 10)).padding(12)
                List(selection: $selection) {
                    Section("Switchboard") {
                        ForEach(model.jobLedger.jobs.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { job in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(job.name).font(.ui(.callout).weight(.medium))
                                Text(job.engine.title + " · " + (job.enabled ? L10n.text("Включено", "Enabled") : L10n.text("Пауза", "Paused"))).font(.ui(.caption)).foregroundStyle(.secondary)
                            }.padding(.vertical, 6).tag(job.id.uuidString)
                        }
                    }
                    if !model.jobs.isEmpty {
                    Section(L10n.text("Доступны для импорта", "Available to import")) {
                        ForEach(model.jobs.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { job in
                            VStack(alignment: .leading) { Text(job.name); Text(job.engine.title).font(.ui(.caption)).foregroundStyle(.secondary) }.tag("source:" + job.id)
                        }
                    }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    .overlay {
                        if !search.isEmpty && !model.jobLedger.jobs.contains(where: { $0.name.localizedCaseInsensitiveContains(search) }) && !model.jobs.contains(where: { $0.name.localizedCaseInsensitiveContains(search) }) {
                            Text(L10n.text("Ничего не найдено", "No results")).font(.ui(.callout)).foregroundStyle(.secondary)
                        }
                    }
                }.background(DeskPalette.sidebar).frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                if let job = model.jobLedger.jobs.first(where: { $0.id.uuidString == selection }) {
                    managedDetail(job)
                } else if let source = model.jobs.first(where: { "source:" + $0.id == selection }) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(L10n.text("Импорт создаёт отдельное задание. Исходное расписание останется без изменений.", "Import creates a separate task. The original schedule stays unchanged.")).font(.ui(.caption))
                            Spacer()
                            Button(L10n.text("Импортировать…", "Import…")) { editing = model.importedJob(source) }.disabled(!model.schedulerReady || source.prompt.isEmpty)
                        }.padding()
                        JobDetail(job: source)
                    }
                } else {
                    EmptyState(icon: "calendar", title: L10n.text("Расписание", "Schedule"), text: L10n.text("Создай задание или выбери существующее для импорта.", "Create a task or select an existing one to import."))
                }
            }
        }
        .onAppear { if selection == nil { selection = model.jobLedger.jobs.first?.id.uuidString } }
        .onChange(of: model.jobLedger.jobs.map(\.id)) { _, ids in
            if selection == nil || (selection?.hasPrefix("source:") == false && !ids.contains(where: { $0.uuidString == selection })) {
                selection = ids.first?.uuidString
            }
        }
        .background(DeskPalette.canvas)
        .buttonStyle(DeskButtonStyle())
        .sheet(item: $editing) { job in JobEditor(model: model, job: job) }
        .sheet(isPresented: $showingRoutines) { RoutineLibrary(model: model) }
        .confirmationDialog(L10n.text("Удалить задание и историю его запусков?", "Delete this task and its run history?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.text("Удалить", "Delete"), role: .destructive) { if let job = deleting { Task { await model.deleteJob(job.id) } }; deleting = nil }
        }
    }
    private var pageTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("Рутины и расписание", "Routines and schedules")).font(.ui(.title2).bold())
            Text(L10n.text("Задания, результаты и библиотека повторяемой работы", "Tasks, results and a library of repeatable work")).font(.ui(.callout)).foregroundStyle(.secondary)
        }
    }
    private var pageActions: some View {
        HStack {
            Button(L10n.text("Библиотека рутин", "Routine library")) { showingRoutines = true }
            Button(L10n.text("Обновить", "Refresh")) { Task { await model.refreshJobs() } }
            Button(L10n.text("Создать", "New task"), systemImage: "plus") {
                var job = ManagedJob(); job.projectID = model.projectID; job.model = model.currentAgent == .originalCodex ? model.currentModel : model.state.model; job.effort = model.currentAgent == .originalCodex ? model.effort : ""; job.route = model.defaultRoute; editing = job
            }.disabled(!model.schedulerReady)
        }
    }
    private func jobDate(_ date: Date, zone: String) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.locale
        formatter.dateStyle = .medium; formatter.timeStyle = .short; formatter.timeZone = TimeZone(identifier: zone)
        return formatter.string(from: date)
    }
    @ViewBuilder private func taskActions(_ job: ManagedJob, active: Bool) -> some View {
                    Button(L10n.text("Запустить сейчас", "Run now")) { Task { await model.launchJob(job.id) } }.disabled(active || !model.schedulerReady || model.routineIssue(job) != nil || model.jobLedger.runs.filter { $0.status.active }.count >= 3)
                    Button(job.enabled ? L10n.text("Пауза", "Pause") : L10n.text("Включить", "Enable")) { Task { await model.toggleJob(job) } }.disabled(active || !model.schedulerReady || (job.schedule.rule.isEmpty && job.schedule.once == nil))
                    Button(L10n.text("Изменить", "Edit")) { editing = job }.disabled(active || !model.schedulerReady)
                    Button(role: .destructive) { deleting = job } label: { Image(systemName: "trash") }.accessibilityLabel(L10n.text("Удалить задание", "Delete task")).disabled(active || !model.schedulerReady)
    }
    private func managedDetail(_ job: ManagedJob) -> some View {
        let active = model.jobLedger.runs.first { $0.jobID == job.id && $0.status.active }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(job.name).font(.ui(.title2).bold())
                ViewThatFits(in: .horizontal) {
                    HStack { taskActions(job, active: active != nil) }
                    VStack(alignment: .leading) { taskActions(job, active: active != nil) }
                }
                RoutineCard {
                LabeledContent(L10n.text("Исполнитель", "Agent"), value: job.engine.title)
                if let routine = job.routine {
                    Text(L10n.text("Рутина", "Routine") + ": \(routine.definition.name) · \(routine.definition.revision.uuidString)").font(.ui(.caption)).textSelection(.enabled)
                    if let issue = model.routineIssue(job) { Text(issue).font(.ui(.caption)).foregroundStyle(.orange) }
                }
                LabeledContent(L10n.text("Проект", "Project"), value: model.state.projects.first { $0.id == job.projectID }?.path ?? L10n.text("Недоступен", "Unavailable"))
                LabeledContent(L10n.text("Часовой пояс", "Time zone"), value: job.schedule.timeZone)
                if let next = job.nextRun, job.enabled { LabeledContent(L10n.text("Следующий запуск", "Next run")) { Text(jobDate(next, zone: job.schedule.timeZone)).textSelection(.enabled) } }
                Text(job.schedule.once != nil ? L10n.text("Однократно", "Once") : job.schedule.rule.isEmpty ? L10n.text("Только вручную", "Manual only") : ScheduledJobs.readableSchedule(job.schedule.rule)).font(.ui(.callout)).textSelection(.enabled)
                if let project = model.state.projects.first(where: { $0.id == job.projectID }) {
                    let role = job.role(project: project, catalog: model.roleCatalog)
                    LabeledContent(L10n.text("Роль запусков", "Run role")) {
                        Text(role.title + (role.profile.audit ? " · " + L10n.text("аудит", "audit") : "")).textSelection(.enabled)
                    }
                }
                if job.engine == .codex {
                    Text(L10n.text("Каждый запуск создаёт новый чат с ролью задания (не выше роли проекта для заданий).", "Each run creates a new chat with the job's role (never above the project's job role).")).font(.ui(.caption)).foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("Claude Code использует существующий вход и правила разрешений CLI. Новые запросы разрешений отклоняются; результат сохраняется здесь. Требуется версия \(AgentIntegrationFactory.claudeVersion).", "Claude Code uses existing CLI sign-in and permission rules. New permission requests are denied; results are saved here. Version \(AgentIntegrationFactory.claudeVersion) is required.")).font(.ui(.caption)).foregroundStyle(.secondary)
                }
                }
                RoutineCard {
                    Text(L10n.text("Инструкции", "Instructions")).font(.ui(.headline))
                    Text(job.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                Text(L10n.text("История запусков", "Run history")).font(.ui(.headline))
                if !model.jobLedger.runs.contains(where: { $0.jobID == job.id }) {
                    RoutineNotice(icon: "clock", text: L10n.text("Запусков пока нет. Здесь появятся результаты и ссылки на чаты.", "No runs yet. Results and conversation links will appear here."))
                }
                ForEach(model.jobLedger.runs.filter { $0.jobID == job.id }) { run in
                    RoutineCard {
                        HStack {
                            Text(jobDate(run.started, zone: job.schedule.timeZone)).font(.ui(.callout))
                            Text(run.status.title).font(.ui(.caption)).foregroundStyle(.secondary)
                            Spacer()
                            if run.status.active { Button(L10n.text("Остановить", "Stop")) { Task { await model.stopJob(run) } } }
                            if let id = run.threadID, let chat = model.state.chats.first(where: { $0.id == id }) {
                                Button(L10n.text("Открыть чат", "Open chat")) { Task { await model.openChat(chat) } }
                            }
                        }
                        if !run.output.isEmpty {
                            DisclosureGroup(L10n.text("Результат запуска", "Run output")) {
                                Text(run.output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }
                        }
                        if let routine = run.routine {
                            DisclosureGroup(L10n.text("Рутина этого запуска", "Routine used for this run")) {
                                Text((try? routine.prompt()) ?? L10n.text("Сохранённая рутина недоступна", "Saved routine unavailable")).font(.ui(.caption)).textSelection(.enabled)
                            }
                        }
                        if run.status == .uncertain { Text(L10n.text("Результат этого запуска не подтверждён. Автоматического повтора не было; настройки расписания не изменились. Перед ручным повтором проверь результат.", "This run's outcome is unconfirmed. No automatic retry was made; schedule settings are unchanged. Check the outcome before retrying manually.")).font(.ui(.caption)).foregroundStyle(.orange) }
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct JobEditor: View {
    @ObservedObject var model: DeskModel
    @State var job: ManagedJob
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var validation: String?
    @State private var mode: String
    init(model: DeskModel, job: ManagedJob) {
        self.model = model; self._job = State(initialValue: job)
        self._mode = State(initialValue: job.schedule.once != nil ? "once" : job.schedule.rule.isEmpty ? "manual" : "rule")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Настройка задания", "Task setup")).font(.ui(.title2).bold())
            Text(L10n.text("Выбери исполнителя, инструкции и время запуска.", "Choose an agent, instructions and run time.")).font(.ui(.callout)).foregroundStyle(.secondary)
            Divider()
            Form {
                Section(L10n.text("Основное", "Basics")) {
                TextField(L10n.text("Название", "Name"), text: $job.name)
                Picker(L10n.text("Исполнитель", "Agent"), selection: $job.engine) { ForEach(JobEngine.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .onChange(of: job.engine) { _, engine in
                        job.model = engine == .claude ? ClaudeModel.defaultID : ""
                        job.effort = engine == .claude ? ClaudeEffort.defaultLevel.rawValue : ""
                        job.route = .direct; job.acceptsExternalPolicy = nil; job.browserSessionImport = nil
                    }
                Picker(L10n.text("Проект", "Project"), selection: $job.projectID) {
                    Text(L10n.text("Выбери проект", "Choose a project")).tag(nil as UUID?)
                    ForEach(model.state.projects) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker(L10n.text("Роль", "Role"), selection: $job.roleID) {
                    Text(L10n.text("Как у проекта", "Project default")).tag(nil as String?)
                    ForEach(model.roleCatalog.scheduled) { role in Text(role.title).tag(Optional(role.id)) }
                }
                if let project = model.state.projects.first(where: { $0.id == job.projectID }) {
                    let role = job.role(project: project, catalog: model.roleCatalog)
                    Text(L10n.text("Запуски пойдут с ролью «\(role.title)»: \(role.summary) Роль не поднимается выше роли проекта для заданий.", "Runs use the \(role.title) role: \(role.summary) Never above the project's job role.")).font(.ui(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    TextField(L10n.text("Модель", "Model"), text: $job.model, prompt: Text(L10n.text("По умолчанию", "Default")))
                    if job.engine == .claude {
                        Menu(L10n.text("Выбрать", "Choose")) {
                            Button(L10n.text("Как в CLI", "CLI default")) { job.model = "" }
                            Divider()
                            ForEach(ClaudeModel.current) { entry in
                                Button(entry.menuTitle) { job.model = entry.id }
                            }
                            Menu(L10n.text("Предыдущие поколения", "Previous generations")) {
                                ForEach(ClaudeModel.previous) { entry in
                                    Button(entry.menuTitle) { job.model = entry.id }
                                }
                            }
                        }.fixedSize()
                    }
                }
                }
                Section(L10n.text("Инструкции и исполнитель", "Instructions and agent")) {
                Menu(L10n.text("Использовать рутину", "Use routine")) {
                    ForEach(model.routines) { routine in
                        Button(routine.name) {
                            do {
                                let invocation = RoutineInvocation(definition: routine)
                                job.prompt = try invocation.prompt(); job.routine = invocation
                            } catch { validation = error.localizedDescription }
                        }
                    }
                }
                if let routine = job.routine {
                    Text(L10n.text("Сохранённая версия рутины", "Frozen routine revision") + ": \(routine.definition.name) · \(routine.definition.revision.uuidString)").font(.ui(.caption)).textSelection(.enabled)
                    TextField(L10n.text("Входные данные этого задания", "Input for this task"), text: Binding(get: { job.routine?.input ?? "" }, set: { value in
                        job.routine?.input = value
                        do { job.prompt = try job.routine?.prompt() ?? ""; validation = nil }
                        catch { job.prompt = ""; validation = error.localizedDescription }
                    }), axis: .vertical)
                    if let issue = model.routineIssue(job) { Text(issue).foregroundStyle(.orange).font(.ui(.caption)) }
                    Button(L10n.text("Преобразовать в обычные инструкции", "Convert to plain instructions")) { job.routine = nil }
                }
                if job.engine == .codex {
                    Picker(L10n.text("Маршрут", "Route"), selection: $job.route) { ForEach(model.availableRoutes, id: \.self) { route in
                        Text(model.routeTitle(route)).tag(route).disabled(model.routeCompatibilityIssue(route) != nil)
                    } }
                    TextField(L10n.text("Рассуждение", "Reasoning effort"), text: $job.effort, prompt: Text(L10n.text("По умолчанию", "Default")))
                }
                ScheduledBrowserImportEditor(policy: $job.browserSessionImport)
                if job.engine == .claude {
                    if job.route != .direct {
                        Text(model.routeCompatibilityIssue(job.route, agent: .claudeCode) ?? "").foregroundStyle(.orange).font(.ui(.caption))
                        Button(L10n.text("Работать напрямую", "Work directly")) { job.route = .direct }
                    }
                    Picker(L10n.text("Рассуждение", "Reasoning effort"), selection: $job.effort) {
                        Text(L10n.text("Как в CLI", "CLI default")).tag("")
                        ForEach(ClaudeEffort.allCases, id: \.rawValue) { level in Text(level.title).tag(level.rawValue) }
                    }
                    Text(L10n.text("Claude работает в профиле Claude приложения, как обычный чат: каждый запуск появляется чатом, который можно продолжить. Разрешения задаёт режим доступа проекта; при полном доступе действия коннекторов claude.ai (Gmail, Calendar…) выполняются без подтверждения. Нужен вход по подписке Claude в настройках.", "Claude runs in the app's Claude profile like a regular chat: each run appears as a chat you can continue. The project's access mode sets permissions; with full access, claude.ai connector actions (Gmail, Calendar…) run without approval. Requires signing in with your Claude subscription in settings.")).font(.ui(.caption)).frame(maxWidth: 460, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                }
                Section(L10n.text("Расписание", "Schedule")) {
                Picker(L10n.text("Расписание", "Schedule"), selection: $mode) {
                    Text(L10n.text("Повторять", "Repeat")).tag("rule")
                    Text(L10n.text("Однократно", "Once")).tag("once")
                    Text(L10n.text("Вручную", "Manual")).tag("manual")
                }.onChange(of: mode) { _, value in
                    if value == "once" { job.schedule.once = Date().addingTimeInterval(3600) }
                    else { job.schedule.once = nil }
                    if value == "manual" { job.schedule.rule = ""; job.enabled = false }
                    if value == "rule" && job.schedule.rule.isEmpty { job.schedule.rule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0" }
                }
                if mode == "once" {
                    DatePicker(L10n.text("Дата и время", "Date and time"), selection: Binding(get: { job.schedule.once ?? Date() }, set: { job.schedule.once = $0 })).environment(\.timeZone, TimeZone(identifier: job.schedule.timeZone) ?? .current)
                } else if mode == "rule" {
                    HStack {
                        Button(L10n.text("Каждый час", "Hourly")) { job.schedule.rule = "FREQ=HOURLY;INTERVAL=1" }
                        Button(L10n.text("Ежедневно", "Daily")) { job.schedule.rule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0" }
                        Button(L10n.text("Будни", "Weekdays")) { job.schedule.rule = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0" }
                    }
                    if simpleDailyTime {
                        DatePicker(L10n.text("Время запуска", "Run at"), selection: scheduleTime, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, TimeZone(identifier: job.schedule.timeZone) ?? .current)
                    }
                    if intervalFrequency != nil {
                        Stepper(value: scheduleInterval, in: 1...1440) {
                            Text(intervalFrequency == "HOURLY"
                                 ? L10n.text("Каждые \(scheduleInterval.wrappedValue) ч.", "Every \(scheduleInterval.wrappedValue) hr")
                                 : L10n.text("Каждые \(scheduleInterval.wrappedValue) мин.", "Every \(scheduleInterval.wrappedValue) min"))
                        }
                    }
                    DisclosureGroup(L10n.text("Точное правило расписания", "Exact schedule rule")) {
                        TextField("RRULE", text: $job.schedule.rule)
                        Text(L10n.text("Минуты: FREQ=MINUTELY;INTERVAL=15. Дни недели: MO,TU,WE,TH,FR,SA,SU. Можно указать несколько часов через запятую.", "Minutes: FREQ=MINUTELY;INTERVAL=15. Weekdays: MO,TU,WE,TH,FR,SA,SU. Multiple hours can be separated by commas.")).font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                }
                TextField(L10n.text("Часовой пояс", "Time zone"), text: $job.schedule.timeZone)
                if job.source != nil {
                    Text(L10n.text("Импорт переносит только инструкции. История исходного чата, рабочие деревья и разрешения не переносятся. Проверь проект, модель, время и часовой пояс. Перед включением отключи исходное расписание.", "Import transfers instructions only. Source chat history, worktrees and permissions are not transferred. Review the project, model, time and time zone. Disable the original schedule before enabling this one.")).font(.ui(.caption))
                    Toggle(L10n.text("Исходное расписание отключено", "I disabled the original schedule"), isOn: $job.sourceDisabled)
                }
                Toggle(L10n.text("Включить расписание", "Enable schedule"), isOn: $job.enabled).disabled(mode == "manual")
                }
                Section {
                    RoutineTextField(label: L10n.text("Инструкции", "Instructions"), text: $job.prompt).disabled(job.routine != nil)
                }
            }.formStyle(.grouped).disabled(saving)
            if let validation { Text(validation).foregroundStyle(.red).font(.ui(.caption)) }
            Divider()
            HStack {
                if saving { ProgressView().uiSmallSpinner() }
                Spacer()
                Button(L10n.text("Отмена", "Cancel")) { dismiss() }.disabled(saving).keyboardShortcut(.cancelAction)
                Button(L10n.text("Сохранить", "Save")) {
                    do {
                        try job.validate()
                        if job.enabled, let once = job.schedule.once, once <= Date() { throw JobSchedule.invalid }
                        saving = true
                        Task { if await model.saveJob(job) { dismiss() } else { validation = model.error }; saving = false }
                    } catch { validation = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(saving)
            }
        }.padding(24).frame(width: 720, height: 740).background(DeskPalette.canvas)
            .buttonStyle(DeskButtonStyle()).interactiveDismissDisabled(saving).task { await model.loadRoutines() }

    }
    private var ruleFields: [String: String] {
        let rule = job.schedule.rule.replacingOccurrences(of: "RRULE:", with: "")
        return rule.split(separator: ";").reduce(into: [:]) { result, part in
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
    }
    private var simpleDailyTime: Bool {
        ["DAILY", "WEEKLY"].contains(ruleFields["FREQ"] ?? "") && Int(ruleFields["BYHOUR"] ?? "") != nil && Int(ruleFields["BYMINUTE"] ?? "") != nil
    }
    private var intervalFrequency: String? {
        let fields = ruleFields
        return Set(fields.keys).isSubset(of: ["FREQ", "INTERVAL"]) && ["HOURLY", "MINUTELY"].contains(fields["FREQ"] ?? "") ? fields["FREQ"] : nil
    }
    private var scheduleInterval: Binding<Int> {
        Binding(get: { Int(ruleFields["INTERVAL"] ?? "1") ?? 1 }, set: { job.schedule.rule = "FREQ=" + (intervalFrequency ?? "HOURLY") + ";INTERVAL=\($0)" })
    }
    private var scheduleTime: Binding<Date> {
        Binding(get: {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: job.schedule.timeZone) ?? .current
            return calendar.date(bySettingHour: Int(ruleFields["BYHOUR"] ?? "9") ?? 9, minute: Int(ruleFields["BYMINUTE"] ?? "0") ?? 0, second: 0, of: Date()) ?? Date()
        }, set: { date in
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: job.schedule.timeZone) ?? .current
            var fields = ruleFields; fields["BYHOUR"] = String(calendar.component(.hour, from: date)); fields["BYMINUTE"] = String(calendar.component(.minute, from: date))
            job.schedule.rule = fields.keys.sorted().map { $0 + "=" + fields[$0]! }.joined(separator: ";")
        })
    }

}
