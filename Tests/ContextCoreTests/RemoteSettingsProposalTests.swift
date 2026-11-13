import Foundation
import Testing
@testable import ContextCore

private func remoteProposalFixture() -> (SavedState, SettingsProposal) {
    var state = SavedState()
    var project = Project(path: "/Users/fixture/app")
    project.accessPresets = []
    state.projects = [project]
    state.chats = [Chat(id: "origin", projectID: project.id, title: "Work", model: "fixture")]
    var change = SettingsProposal.Change(project: project.path)
    change.addPresets = ["swift"]
    return (state, SettingsProposal(chat: "origin", reason: "Build", changes: [change]))
}

@Test func settingsRequestsRequirePublishedExactContentAndSingleUse() throws {
    let (state, proposal) = remoteProposalFixture()
    let review = SettingsProposalReview(id: "request.json", proposal: proposal, state: state)
    var requests = RemoteSettingsProposals()
    requests.refresh([review], state: state)
    let shared: Set<String> = [state.projects[0].id.uuidString]
    #expect(requests.approvals(chat: "other", sharedProjects: shared).isEmpty)
    #expect(requests.approvals(chat: "origin", sharedProjects: []).isEmpty)
    let card = try #require(requests.approvals(chat: "origin", sharedProjects: shared).first)
    #expect(card.projectSettings == true && card.canAllow)
    requests.refresh([review], state: state)
    #expect(requests.approvals(chat: "origin", sharedProjects: shared).first?.id == card.id)
    #expect(requests.take(handle: card.id, chat: "other", allow: true, sharedProjects: shared) == nil)
    #expect(requests.take(handle: card.id, chat: "origin", allow: true, sharedProjects: []) == nil)
    #expect(requests.take(handle: card.id, chat: "origin", allow: true, sharedProjects: shared) == review)
    #expect(requests.take(handle: card.id, chat: "origin", allow: true, sharedProjects: shared) == nil)
}

@Test func settingsRequestsExpireAfterFileOrProjectChangesAndRestart() throws {
    var (state, proposal) = remoteProposalFixture()
    let shared: Set<String> = [state.projects[0].id.uuidString]
    var requests = RemoteSettingsProposals()
    func review() -> SettingsProposalReview { .init(id: "same.json", proposal: proposal, state: state) }
    requests.refresh([review()], state: state)
    let first = try #require(requests.approvals(chat: "origin", sharedProjects: shared).first)
    proposal.changes[0].addPresets = ["apple-signing"]
    requests.refresh([review()], state: state)
    #expect(requests.take(handle: first.id, chat: "origin", allow: true, sharedProjects: shared) == nil)
    let second = try #require(requests.approvals(chat: "origin", sharedProjects: shared).first)
    state.projects[0].extraRoots = [.init(path: "/tmp/other", writable: false)]
    requests.refresh([review()], state: state)
    #expect(requests.take(handle: second.id, chat: "origin", allow: false, sharedProjects: shared) == nil)
    let third = try #require(requests.approvals(chat: "origin", sharedProjects: shared).first)
    var restarted = RemoteSettingsProposals()
    restarted.refresh([review()], state: state)
    #expect(restarted.take(handle: third.id, chat: "origin", allow: true, sharedProjects: shared) == nil)
    requests.refresh([], state: state)
    #expect(requests.take(handle: third.id, chat: "origin", allow: true, sharedProjects: shared) == nil)
}

@Test func settingsRequestsNeverPublishHiddenProjectsOrApproveIncompleteDetails() throws {
    var (state, proposal) = remoteProposalFixture()
    let shared: Set<String> = [state.projects[0].id.uuidString]
    let hidden = Project(path: "/Users/fixture/private")
    state.projects.append(hidden)
    var change = SettingsProposal.Change(project: hidden.path); change.sandbox = false
    proposal.changes.append(change)
    var requests = RemoteSettingsProposals()
    requests.refresh([.init(id: "multi.json", proposal: proposal, state: state)], state: state)
    #expect(requests.approvals(chat: "origin", sharedProjects: shared).isEmpty)
    proposal.changes.removeLast()
    proposal.changes[0].addPresets = ["swift", "unknown"]
    requests.refresh([.init(id: "partial.json", proposal: proposal, state: state)], state: state)
    let partial = try #require(requests.approvals(chat: "origin", sharedProjects: shared).first)
    #expect(!partial.canAllow)
    #expect(requests.take(handle: partial.id, chat: "origin", allow: true, sharedProjects: shared) == nil)
    #expect(requests.take(handle: partial.id, chat: "origin", allow: false, sharedProjects: shared) != nil)
    proposal.changes[0].addPresets = ["swift"]
    proposal.changes[0].addCommands = (0..<60).map { "echo \($0) " + String(repeating: "x", count: 180) }
    requests.refresh([.init(id: "long.json", proposal: proposal, state: state)], state: state)
    let long = try #require(requests.approvals(chat: "origin", sharedProjects: shared).first)
    #expect(!long.canAllow && long.details.count == 8000)
    #expect(requests.take(handle: long.id, chat: "origin", allow: true, sharedProjects: shared) == nil)
}

@Test func settingsRequestCopyStatesPersistentScopeInBothLanguagesAndKeepsOldProtocol() throws {
    let (state, proposal) = remoteProposalFixture()
    let review = SettingsProposalReview(id: "p.json", proposal: proposal, state: state)
    #expect(review.remoteDetails(language: .russian).contains("постоянное изменение"))
    #expect(review.remoteDetails(language: .english).contains("permanently changes"))
    #expect(review.remoteDetails(language: .english).contains("+ Access set: swift"))
    let old = try JSONDecoder().decode(RemoteApproval.self, from: Data(#"{"id":"old","details":"command","canAllow":true}"#.utf8))
    #expect(old.projectSettings == nil && old.canAllow)
}

@Test func mobileSettingsReviewIncludesKeychainSecretsAndRemovalsInBothLanguages() {
    var (state, proposal) = remoteProposalFixture()
    state.projects[0].keychainItems = [.init(service: "old-service", account: "old-account")]
    proposal.changes[0].addKeychainItems = [.init(service: "new-service", account: "new-account")]
    proposal.changes[0].removeKeychainItems = [.init(service: "old-service", account: "old-account")]
    let review = SettingsProposalReview(id: "keys.json", proposal: proposal, state: state)
    for language in [AppLanguage.russian, .english] {
        let details = review.remoteDetails(language: language)
        #expect(details.contains(KeychainItemRule.addLine(.init(service: "new-service", account: "new-account"), language: language)))
        #expect(details.contains(KeychainItemRule.removeLine(.init(service: "old-service", account: "old-account"), language: language)))
    }
}

@Test func mobileSettingsHandlesExpireWhenBoundaryReviewChanges() throws {
    let (state, proposal) = remoteProposalFixture()
    let review = SettingsProposalReview(id: "commands.json", proposal: proposal, state: state)
    let shared: Set<String> = [state.projects[0].id.uuidString]
    var requests = RemoteSettingsProposals()
    requests.refresh([review], state: state)
    let first = try #require(requests.approvals(chat: "origin", sharedProjects: shared).first)
    let note = SettingsProposalBoundaryNote(projectID: state.projects[0].id, command: "fixture", provider: "Codex", effect: .noExtraAccess(set: nil))
    requests.refresh([review], state: state, boundaryNotes: { _ in [note] })
    #expect(requests.take(handle: first.id, chat: "origin", allow: true, sharedProjects: shared) == nil)
    let updated = try #require(requests.approvals(chat: "origin", sharedProjects: shared).first)
    #expect(updated.details.contains(note.text()))
}

@Test func mobileSettingsDecisionMatchesDatabaseUUIDCasingAndConsumesOnce() throws {
    let (state, proposal) = remoteProposalFixture()
    let review = SettingsProposalReview(id: "uuid.json", proposal: proposal, state: state)
    let shared: Set<String> = [state.projects[0].id.uuidString]
    for allow in [true, false] {
        var requests = RemoteSettingsProposals()
        requests.refresh([review], state: state)
        let card = try #require(requests.approvals(chat: "origin", sharedProjects: shared).first)
        // PostgreSQL uuid output uses lower-case hex, while Foundation uuidString uses upper-case.
        let databaseHandle = card.id.lowercased()
        #expect(requests.take(handle: "invalid", chat: "origin", allow: allow, sharedProjects: shared) == nil)
        #expect(requests.take(handle: databaseHandle, chat: "origin", allow: allow, sharedProjects: shared) == review)
        #expect(requests.take(handle: card.id.uppercased(), chat: "origin", allow: allow, sharedProjects: shared) == nil)
    }
}
