import Testing
import ContextCore
import ClaudeAdapter

@Test func autonomyGuidanceIsLocalizedAndSeparateFromPermissionFlags() {
    let ru = AgentAutonomy.instructions(language: .russian)
    let en = AgentAutonomy.instructions(language: .english)
    #expect(ru.contains("Автономность в Switchboard"))
    #expect(en.contains("Autonomy in Switchboard"))
    #expect(ru.contains("Не считай молчание согласием"))
    #expect(en.contains("Silence is not consent"))
    let arguments = ClaudeJobRunner.arguments(model: "model", effort: nil)
    #expect(arguments.contains("dontAsk"))
    #expect(!arguments.contains("bypassPermissions"))
    #expect(arguments.filter { $0 == "--append-system-prompt" }.count == 1)
    #expect(arguments.contains(AgentAutonomy.instructions()))
}

@Test func heavyWorkRuleIsSharedInBothLanguages() {
    let ru = AgentAutonomy.instructions(language: .russian)
    let en = AgentAutonomy.instructions(language: .english)
    #expect(ru.contains("Тяжёлая работа в Switchboard") && ru.contains("не больше 2 тяжёлых шагов") && ru.contains("vm.loadavg"))
    #expect(en.contains("Heavy work in Switchboard") && en.contains("At most 2 heavy steps") && en.contains("vm.loadavg"))
    // The app's diagnostics come first; the shell fallback never asks to leave the sandbox.
    #expect(ru.contains("`project_diagnostics` (`load`, `heavy_tasks`); без него") && en.contains("`project_diagnostics` (`load`, `heavy_tasks`); without it"))
    #expect(!ru.contains("dangerouslyDisableSandbox") && !en.contains("dangerouslyDisableSandbox"))
}

@Test func refusalRuleReachesEveryChatInBothLanguages() {
    let ru = AgentAutonomy.instructions(language: .russian)
    let en = AgentAutonomy.instructions(language: .english)
    #expect(ru.contains("После отказа в Switchboard") && en.contains("After a refusal in Switchboard"))
    // A bare OS refusal is covered; no workaround; the app's tools first; one request through the inbox; continue.
    for text in [ru, en] {
        #expect(text.contains("Operation not permitted") && text.contains("$SWITCHBOARD_SETTINGS_PROPOSALS"))
        for tool in ["project_diagnostics", "inspect_chat", "app_log", "request_app_restart"] { #expect(text.contains(tool), "\(tool)") }
    }
    #expect(ru.contains("не ищи другую команду, интерпретатор, путь или флаг") && en.contains("do not look for another command, interpreter, path or flag"))
    #expect(ru.contains("один запрос доступа") && en.contains("one access request"))
    #expect(ru.contains("сообщи пользователю, какого доступа не хватает") && en.contains("tell the user which access is missing"))
    #expect(ru.contains("назови открытый запрос в итоговом сообщении") && en.contains("name the open request in the final message"))
    // Same place in both languages: after autonomy, before browsers.
    for (text, sections) in [(ru, ["Автономность", "После отказа", "Браузеры"]), (en, ["Autonomy", "After a refusal", "Browsers"])] {
        let positions = sections.compactMap { text.range(of: $0)?.lowerBound }
        #expect(positions.count == 3 && positions == positions.sorted())
    }
}

@Test func chatReferenceRuleNamesTheInspectTool() {
    let ru = AgentAutonomy.instructions(language: .russian)
    let en = AgentAutonomy.instructions(language: .english)
    #expect(ru.contains("switchboard-chat:<UUID>") && ru.contains("inspect_chat"))
    #expect(en.contains("switchboard-chat:<UUID>") && en.contains("inspect_chat"))
}

@Test func verificationQueueGuidancePreservesTaskOwnershipAndPublicationGates() {
    let ru = AgentAutonomy.instructions(language: .russian)
    let en = AgentAutonomy.instructions(language: .english)
    #expect(ru.contains("общую очередь проверок") && ru.contains("разрешение публикации"))
    #expect(en.contains("shared verification queue") && en.contains("publication authorization"))
}
