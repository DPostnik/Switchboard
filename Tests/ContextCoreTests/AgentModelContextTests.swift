import Foundation
import Testing
import ContextCore
import ClaudeAdapter

@Test func currentModelContextDistinguishesSelectionFromBackendAndScopesChildren() {
    for language in [AppLanguage.russian, .english] {
        let astra = AgentModelContext.instructions(model: "gpt-6-astra", provider: .codex, language: language)
        let fable = AgentModelContext.instructions(model: "claude-fable-5-2", provider: .claude, language: language)
        #expect(astra.contains("gpt-6-astra") && astra.contains("gpt-6.2-sol") && astra.contains("fork_turns"))
        #expect(fable.contains("claude-fable-5-2") && fable.contains("Opus 5.5 (model: \"opus\")") && !fable.contains("sonnet"))
        let sol = AgentModelContext.instructions(model: "gpt-6.2-sol", provider: .codex, language: language)
        #expect(!sol.contains("fork_turns") && !sol.contains("gpt-6-astra"))
        let unset = AgentModelContext.instructions(model: "", provider: .codex, language: language)
        #expect(!unset.contains("gpt-6-astra") && !unset.contains("gpt-6.2-sol"))
        let priority = language == .russian
            ? "Явные указания пользователя о делегировании в этом чате или задаче имеют приоритет"
            : "Explicit user instructions about delegation for this chat or task take precedence"
        let directWork = language == .russian ? "выполни её без подагентов" : "implement it without subagents"
        for context in [astra, fable, sol, unset] {
            #expect(context.contains(priority))
            #expect(context.contains(directWork))
        }
        #expect(astra != sol && sol != unset)
        let astra62 = AgentModelContext.instructions(model: "gpt-6.2-astra", provider: .codex, language: language)
        #expect(astra62.contains("gpt-6.2-astra") && astra62.contains("fork_turns"))
        for plain in ["gpt-6.2-sol", "gpt-6.2-astra-preview", "my-gpt-6-astra"] {
            #expect(!AgentModelContext.instructions(model: plain, provider: .codex, language: language).contains("fork_turns"))
        }
    }
    let en = AgentModelContext.instructions(model: "gpt-6-astra", provider: .codex, language: .english)
    #expect(en.contains("not a verified provider backend") && en.contains("Subagents do not inherit this identity or role"))
    #expect(en.contains("Do not ask the user which model is selected"))
    #expect(AgentModelContext.instructions(model: "", provider: .codex, language: .english).contains("No explicit model override"))
    let custom = "custom\"\nmodel"
    let encoded = String(decoding: try! JSONEncoder().encode(custom), as: UTF8.self)
    #expect(AgentModelContext.instructions(model: custom, provider: .codex, language: .english).contains(encoded))
    #expect(!AgentModelContext.instructions(model: "claude-fable-5-2", provider: .codex, language: .english).contains("model: \"opus\""))
}

@Test func scheduledClaudePromptUsesEachRunsSelectedModel() throws {
    for model in ["claude-fable-5-2", "claude-sonnet-5-5", ""] {
        let args = ClaudeJobRunner.arguments(model: model, effort: nil)
        let index = try #require(args.firstIndex(of: "--append-system-prompt"))
        #expect(args[index + 1].hasSuffix(AgentModelContext.instructions(model: model, provider: .claude)))
    }
}
