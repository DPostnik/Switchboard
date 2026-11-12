import Foundation
import AgentContract

/// What an added trusted command (`addCommands`) does for chats that run under the external boundary. Under the boundary a
/// trusted command does not leave it: only a mediated command and the app's own tools do (PERMISSIONS.md, section 1). The
/// review shows this before the user decides (channel 4); it never blocks Apply.
public struct SettingsProposalBoundaryNote: Equatable, Sendable {
    public enum Effect: Equatable, Sendable {
        /// The chats stay under the boundary; the command still runs inside it and gets no extra access there. `set`: an
        /// access set whose mediated command would run it.
        case noExtraAccess(set: String?)
        /// The boundary cannot run the command (the command inventory): applying moves these chats to the provider's own
        /// sandbox with approval prompts.
        case leavesBoundary(set: String?)
    }
    public var projectID: UUID
    public var command: String
    /// The provider whose chats this is about ("Claude", "Codex"): a product name from the app, never agent text.
    public var provider: String
    public var effect: Effect
    public init(projectID: UUID, command: String, provider: String, effect: Effect) {
        self.projectID = projectID; self.command = command; self.provider = provider; self.effect = effect
    }

    /// One warning line, RU/EN (invariant 16). The command itself is shown next to it as data.
    public func text(language: AppLanguage = L10n.language) -> String {
        func set(_ id: String) -> String { AccessPresetCatalog.preset(id)?.title(language: language) ?? id }
        switch effect {
        case .noExtraAccess(let id):
            let instead = id.map { L10n.text("набор доступа «\(set($0))» (его команда-посредник выполняет её со Связкой ключей или сетью), ",
                                             "the access set “\(set($0))” (its mediated command runs this with the Keychain or network), ",
                                             language: language) } ?? ""
            return L10n.text(
                "Чаты \(provider) этого проекта работают под внешней границей: эта команда всё равно выполнится внутри неё и не получит там дополнительного доступа. Вместо этого: \(instead)инструмент приложения, доступ к папке или доступ к элементу Связки ключей (планируется).",
                "\(provider) chats of this project run under the external boundary: this command will still run inside it and gets no extra access there. Instead: \(instead)an app-owned tool, a folder grant, or a Keychain item grant (planned).",
                language: language)
        case .leavesBoundary(let id):
            let instead = id.map { L10n.text(" Вместо этого: набор доступа «\(set($0))» выполняет её как команду-посредника.",
                                             " Instead: the access set “\(set($0))” runs it as a mediated command.", language: language) } ?? ""
            return L10n.text(
                "Внешняя граница не может выполнить эту команду: после применения чаты \(provider) этого проекта уйдут с границы в собственную песочницу провайдера с запросами подтверждения.\(instead)",
                "The external boundary cannot run this command: applying it moves this project's \(provider) chats off the boundary to the provider's own sandbox with approval prompts.\(instead)",
                language: language)
        }
    }
}

/// Decides the notes with the planner the adapters launch with (`ExternalSandboxPlanner.plan`, command inventory and mediated
/// `pgrep` on, as both adapters set them), for each project as it would be after the proposal. No rule is restated here.
public enum SettingsProposalBoundary {
    /// One kind of chat (a provider and the role its chats get on a project).
    public struct Kind {
        public var provider: String
        /// The planner input for these chats on a project as given; nil when they never run under the boundary there for
        /// reasons outside the project settings (another provider, the rollback switch, the user's Chrome).
        public var input: (Project) -> ExternalSandboxPlanner.Input?
        public init(provider: String, input: @escaping (Project) -> ExternalSandboxPlanner.Input?) { self.provider = provider; self.input = input }
    }

    public static func notes(_ review: SettingsProposalReview, state: SavedState, kinds: [Kind],
                             helper: Result<ExternalSandboxHelper, ExternalSandboxHelper.Failure>) -> [SettingsProposalBoundaryNote] {
        // Without a verified helper no chat runs under the boundary, so a trusted command keeps its native meaning.
        guard case .success = helper else { return [] }
        func plan(_ input: ExternalSandboxPlanner.Input, inventory: Bool) -> ExternalSandboxPlan? {
            var input = input
            input.mediateProcessList = true; input.commandInventory = inventory
            return try? ExternalSandboxPlanner.plan(input, helper: helper).get()
        }
        func project(_ diff: SettingsProposalReview.ProjectDiff) -> Project? {
            var copy = state, single = review
            single.projects = [diff]
            copy.apply(single)
            return copy.projects.first { $0.id == diff.projectID }
        }
        var notes: [SettingsProposalBoundaryNote] = []
        for diff in review.projects where !diff.addCommands.isEmpty {
            var without = diff
            without.addCommands = []
            guard let after = project(diff), let baseline = project(without) else { continue }
            for kind in kinds {
                // Only chats that are under the boundary without the added commands: otherwise the commands keep their
                // native meaning (trusted, outside the CLI sandbox).
                guard let baseInput = kind.input(baseline), plan(baseInput, inventory: true) != nil,
                      let afterInput = kind.input(after), let afterPlan = plan(afterInput, inventory: false) else { continue }
                let mediated = Set(afterPlan.commands.map(\.name))
                for command in diff.addCommands {
                    guard let head = ExternalSandboxPlanner.commandHead(command), !mediated.contains(head) else { continue }
                    let set = coveringSet(head, project: after, kind: kind, plan: { plan($0, inventory: false) })
                    let unrunnable = ExternalSandboxPlanner.unrunnableTrustedCommand([command], mediated: mediated, grants: afterPlan.grants,
                                                                                     home: afterInput.home) != nil
                    notes.append(.init(projectID: diff.projectID, command: command, provider: kind.provider,
                                       effect: unrunnable ? .leavesBoundary(set: set) : .noExtraAccess(set: set)))
                }
            }
        }
        return notes
    }

    /// The first access set, not yet ticked, with which the planner would mediate `head`. Only sets with trusted commands
    /// can change what the planner mediates, so the others are not planned.
    static func coveringSet(_ head: String, project: Project, kind: Kind, plan: (ExternalSandboxPlanner.Input) -> ExternalSandboxPlan?) -> String? {
        let ticked = project.accessPresets ?? []
        for preset in AccessPresetCatalog.all where !ticked.contains(preset.id) && !preset.unsandboxed.isEmpty {
            var candidate = project
            candidate.accessPresets = ticked + [preset.id]
            if let input = kind.input(candidate), plan(input)?.commands.contains(where: { $0.name == head }) == true { return preset.id }
        }
        return nil
    }
}

extension SettingsProposalOutcome {
    /// The outcome after Apply, from app-side facts only: `.appliedWithoutEffect` when the proposal grants nothing new except
    /// trusted commands the requesting chat's boundary keeps inside (each has a `noExtraAccess` note for that chat's kind),
    /// else `.applied`.
    public static func afterApply(_ review: SettingsProposalReview, notes: [SettingsProposalBoundaryNote]) -> Self {
        let commands = review.projects.flatMap { diff in diff.addCommands.map { (diff.projectID, $0) } }
        guard !commands.isEmpty,
              review.projects.allSatisfy({ $0.addPresets.isEmpty && $0.addFolders.isEmpty && $0.sandbox == nil }),
              commands.allSatisfy({ project, command in notes.contains {
                  guard $0.projectID == project, $0.command == command, case .noExtraAccess = $0.effect else { return false }
                  return true
              } }) else { return .applied }
        return .appliedWithoutEffect
    }
}
