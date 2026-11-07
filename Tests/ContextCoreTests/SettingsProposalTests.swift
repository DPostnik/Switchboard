import Foundation
import Testing
import AgentContract
@testable import ContextCore
@testable import ClaudeAdapter

private func sampleState() -> SavedState {
    var state = SavedState()
    var app = Project(path: "/Users/me/app"); app.accessPresets = ["github"]; app.extraRoots = [.init(path: "/Users/me/wiki", writable: false)]
    app.sandboxCommands = ["zsh build.sh"]
    var site = Project(path: "/Users/me/site"); site.accessPresets = []
    state.projects = [app, site]
    return state
}

@Test func proposalReviewKeepsOnlyRealChangesAndNamesWhatItDropped() throws {
    var change = SettingsProposal.Change(project: "~/app")
    change.addPresets = ["github", "vercel", "nope"]
    change.removePresets = ["node"]
    change.addFolders = [.init(path: "~/wiki", writable: true), .init(path: "~/Downloads", writable: false), .init(path: "relative", writable: false),
                         .init(path: "/Users/me/../etc", writable: false)]
    change.removeFolders = ["/Users/me/missing"]
    change.addCommands = ["zsh build.sh", " gh ", "a\nb", ""]
    change.removeCommands = ["zsh build.sh"]
    var other = SettingsProposal.Change(project: "site"); other.sandbox = false
    let unknown = SettingsProposal.Change(project: "/Users/me/elsewhere")
    let review = SettingsProposalReview(id: "p.json", proposal: .init(chat: "c1", reason: "  Needs Vercel  ", changes: [change, other, unknown]),
                                        state: sampleState(), home: "/Users/me")
    #expect(review.reason == "Needs Vercel" && review.chat == "c1")
    let app = try #require(review.projects.first)
    #expect(app.name == "app" && app.addPresets == ["vercel"] && app.removePresets.isEmpty)
    // A known folder whose write flag changes is listed; `..` and relative paths are not.
    #expect(app.addFolders == [.init(path: "/Users/me/wiki", writable: true), .init(path: "/Users/me/Downloads", writable: false)])
    #expect(app.removeFolders.isEmpty && app.addCommands == ["gh"] && app.removeCommands == ["zsh build.sh"])
    #expect(review.projects.last?.name == "site" && review.projects.last?.sandbox == false)
    #expect(review.skipped.count == 6) // unknown set, two bad folders, two bad commands, unknown project
}

@Test func applyingAReviewChangesOnlyWhatItLists() {
    var state = sampleState()
    var change = SettingsProposal.Change(project: "/Users/me/app")
    change.addPresets = ["vercel"]; change.addFolders = [.init(path: "/Users/me/wiki", writable: true)]; change.removeCommands = ["zsh build.sh"]
    let review = SettingsProposalReview(id: "p.json", proposal: .init(changes: [change]), state: state, home: "/Users/me")
    let changed = state.apply(review)
    #expect(changed)
    let app = state.projects[0]
    #expect(app.accessPresets == ["github", "vercel"] && app.extraRoots == [.init(path: "/Users/me/wiki", writable: true)] && app.sandboxCommands == nil)
    #expect(state.projects[1].accessPresets == [])
    // Read again against the new settings, the same proposal changes nothing.
    let again = SettingsProposalReview(id: "p.json", proposal: .init(changes: [change]), state: state, home: "/Users/me")
    let changedAgain = state.apply(again)
    #expect(again.projects.isEmpty && !changedAgain)
}

@Test func inboxDropsUnreadableAndEmptyProposals() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: directory.appendingPathComponent("bad.json"))
    try Data(#"{"changes":[{"project":"/Users/me/app","addPresets":["github"]}]}"#.utf8).write(to: directory.appendingPathComponent("empty.json"))
    try Data(#"{"changes":[{"project":"/Users/me/app","addPresets":["node"]}]}"#.utf8).write(to: directory.appendingPathComponent("good.json"))
    let reviews = SettingsProposalInbox.load(state: sampleState(), directory: directory)
    #expect(reviews.map(\.id) == ["good.json"] && reviews.first?.projects.first?.addPresets == ["node"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["good.json"])
    SettingsProposalInbox.remove("../good.json", directory: directory)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("good.json").path))
    SettingsProposalInbox.remove("good.json", directory: directory)
    #expect(SettingsProposalInbox.load(state: sampleState(), directory: directory).isEmpty)
}

@Test func sandboxedClaudeChatsLearnHowToProposeSettings() throws {
    var project = Project(path: "/Users/me/app"); project.accessPresets = []
    let developer = AgentRoleCatalog.preset(AgentRoleID.developer).profile(for: project)
    let args = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, permissions: developer, model: "", effort: nil, cwd: project.path)
    let settings = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(args.firstIndex(of: "--settings").map { args[$0 + 1] }).utf8))
    #expect(settings["sandbox"]["filesystem"]["allowWrite"].array.contains(.string(SettingsProposalInbox.directory.path)))
    let prompt = try #require(args.firstIndex(of: "--append-system-prompt").map { args[$0 + 1] })
    #expect(prompt.contains(SettingsProposalInbox.environmentKey) && prompt.contains("vercel"))
    // Without a sandbox (the editor has no shell) there is nothing to propose from.
    let editor = try ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false, permissions: AgentRoleCatalog.preset(AgentRoleID.editor).profile(for: project),
                                                 model: "", effort: nil, cwd: project.path)
    #expect(!(editor.firstIndex(of: "--append-system-prompt").map { editor[$0 + 1] } ?? "").contains(SettingsProposalInbox.environmentKey))
}
