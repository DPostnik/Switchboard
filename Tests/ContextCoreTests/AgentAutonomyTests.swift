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
}
