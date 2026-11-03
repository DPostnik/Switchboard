import Foundation
import Testing
import ContextCore
@testable import ContextDesk

private func archive() -> (SavedState, Project, Project) {
    var state = SavedState()
    var wiki = Project(path: "/tmp/super-wiki"); wiki.name = "super-wiki"
    var desk = Project(path: "/tmp/switchboard"); desk.name = "switchboard"
    state.projects = [wiki, desk]
    func chat(_ id: String, _ project: Project, _ title: String, archived: Bool) -> Chat {
        var chat = Chat(id: id, projectID: project.id, title: title, model: "fixture-model")
        chat.archived = archived ? true : nil
        return chat
    }
    state.chats = [
        chat("a", wiki, "Andersen NDA in Gmail", archived: true),
        chat("b", wiki, "Weekly digest", archived: true),
        chat("c", desk, "Archive stutter", archived: true),
        chat("d", wiki, "Andersen questionnaire", archived: false),
    ]
    return (state, wiki, desk)
}

@Test func archiveListingCountsEveryProjectWhateverTheFilter() {
    let (state, wiki, desk) = archive()
    let listing = ArchiveView.listing(state, project: desk.id, search: "digest")
    #expect(listing.total == 3)
    #expect(listing.counts[wiki.id] == 2 && listing.counts[desk.id] == 1)
    #expect(listing.chats.isEmpty && listing.active.isEmpty)
}

@Test func archiveSearchStaysInsideTheSelectedProject() {
    let (state, wiki, _) = archive()
    #expect(ArchiveView.listing(state, project: nil, search: "").chats.map(\.id).sorted() == ["a", "b", "c"])
    #expect(ArchiveView.listing(state, project: wiki.id, search: "").chats.map(\.id).sorted() == ["a", "b"])
    #expect(ArchiveView.listing(state, project: wiki.id, search: "stutter").chats.isEmpty)
    // A project name still matches all of its chats.
    #expect(ArchiveView.listing(state, project: nil, search: "switchboard").chats.map(\.id) == ["c"])
}

@Test func archiveSearchAlsoFindsChatsThatAreNotArchived() {
    let (state, _, desk) = archive()
    let listing = ArchiveView.listing(state, project: nil, search: "andersen")
    #expect(listing.chats.map(\.id) == ["a"])
    #expect(listing.active.map(\.id) == ["d"])
    // Without a search the list shows only the archive.
    #expect(ArchiveView.listing(state, project: nil, search: "").active.isEmpty)
    #expect(ArchiveView.listing(state, project: desk.id, search: "andersen").active.isEmpty)
}

@Test func archiveChatCountUsesRussianPluralForms() {
    #expect([1, 2, 5, 11, 21, 22, 112, 756].map { ArchiveView.chatCount($0, language: .russian) } ==
            ["1 чат", "2 чата", "5 чатов", "11 чатов", "21 чат", "22 чата", "112 чатов", "756 чатов"])
    #expect([1, 756].map { ArchiveView.chatCount($0, language: .english) } == ["1 chat", "756 chats"])
}

@Test func archiveSearchAddsChatsFoundByTheirTextWithASnippet() {
    let (state, _, _) = archive()
    let listing = ArchiveView.listing(state, project: nil, search: "анкета", textMatches: ["b": "…заполнить анкету…", "d": "…анкета Andersen…"])
    #expect(listing.chats.map(\.id) == ["b"] && listing.active.map(\.id) == ["d"])
    #expect(listing.snippets == ["b": "…заполнить анкету…", "d": "…анкета Andersen…"])
    // A title match needs no snippet.
    #expect(ArchiveView.listing(state, project: nil, search: "digest", textMatches: ["b": "…"]).snippets.isEmpty)
}

@Test func archiveListingKeepsTheSidebarOrderOfEveryProject() {
    var (state, wiki, desk) = archive()
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    for index in 0..<40 {
        var chat = Chat(id: "x\(index)", projectID: index % 3 == 0 ? desk.id : wiki.id, title: "Chat \(index)", model: "fixture-model")
        chat.archived = index % 4 == 0 ? nil : true
        chat.sidebarOrder = index % 5 == 0 ? nil : (index * 7) % 11
        chat.updated = base.addingTimeInterval(Double((index * 13) % 17))
        state.chats.append(chat)
    }
    let listing = ArchiveView.listing(state, project: nil, search: "")
    #expect(listing.chats.map(\.id) == state.projects.flatMap { state.orderedChats(projectID: $0.id, archived: true) }.map(\.id))
    let searched = ArchiveView.listing(state, project: nil, search: "chat")
    #expect(searched.active.map(\.id) == state.projects.flatMap { state.orderedChats(projectID: $0.id, archived: false) }
        .filter { $0.title.localizedCaseInsensitiveContains("chat") }.map(\.id))
    #expect(searched.chats.count + searched.active.count == state.chats.count(where: { $0.title.localizedCaseInsensitiveContains("chat") }))
}

@Test func listingFingerprintFollowsWhatTheListsShow() {
    let (state, _, _) = archive()
    var unrelated = state
    // Fields no list shows or orders by leave it alone.
    unrelated.chats[0].model = "other-model"; unrelated.chats[0].effort = "high"
    #expect(unrelated.listingFingerprint == state.listingFingerprint)
    let changes: [(inout SavedState) -> Void] = [
        { $0.chats[0].title = "Renamed" }, { $0.chats[1].archived = nil }, { $0.chats[2].sidebarOrder = 3 },
        { $0.chats[3].updated = Date() }, { $0.chats.removeLast() }, { $0.projects[0].name = "renamed" }, { $0.projects[0].hidden = true },
    ]
    for change in changes {
        var changed = state
        change(&changed)
        #expect(changed.listingFingerprint != state.listingFingerprint)
    }
}
