import AppKit
import ContextCore
import ContextTranscript
import Foundation
import SwiftUI
import Testing
@testable import ContextDesk

@Suite struct PaletteSearchTests {
    @Test func emptyQueryKeepsEverythingNewestFirst() {
        let now = Date()
        let candidates = [
            PaletteSearch.Candidate(id: "old", title: "Old", recency: now.addingTimeInterval(-100)),
            PaletteSearch.Candidate(id: "new", title: "New", recency: now),
            PaletteSearch.Candidate(id: "mid", title: "Mid", recency: now.addingTimeInterval(-10)),
        ]
        #expect(PaletteSearch.rank(candidates, query: "") == ["new", "mid", "old"])
        #expect(PaletteSearch.rank(candidates, query: "  ", limit: 2) == ["new", "mid"])
    }

    @Test func entriesWithoutRecencyKeepTheirOrder() {
        let actions = ["Archive", "Schedule", "Settings"].map { PaletteSearch.Candidate(id: $0, title: $0) }
        #expect(PaletteSearch.rank(actions, query: "") == ["Archive", "Schedule", "Settings"])
        #expect(PaletteSearch.rank(actions, query: "s") == ["Schedule", "Settings"])
    }

    @Test func titleStartBeatsWordStartBeatsSubstringBeatsProject() {
        let now = Date()
        // The weakest match is the newest, so only the score can put it last.
        let candidates = [
            PaletteSearch.Candidate(id: "project", title: "Release notes", detail: "Billing", recency: now),
            PaletteSearch.Candidate(id: "inner", title: "Rebill flow", recency: now.addingTimeInterval(-1)),
            PaletteSearch.Candidate(id: "word", title: "Fix billing bug", recency: now.addingTimeInterval(-2)),
            PaletteSearch.Candidate(id: "start", title: "Billing export", recency: now.addingTimeInterval(-3)),
        ]
        #expect(PaletteSearch.rank(candidates, query: "bill") == ["start", "word", "inner", "project"])
    }

    @Test func everyWordMustMatchInTitleOrProject() {
        let candidates = [
            PaletteSearch.Candidate(id: "a", title: "Fix login", detail: "Switchboard"),
            PaletteSearch.Candidate(id: "b", title: "Fix login", detail: "Fringe"),
            PaletteSearch.Candidate(id: "c", title: "Update docs", detail: "Switchboard"),
        ]
        #expect(PaletteSearch.rank(candidates, query: "login switch") == ["a"])
        #expect(PaletteSearch.rank(candidates, query: "switchboard").sorted() == ["a", "c"])
        #expect(PaletteSearch.rank(candidates, query: "nothing").isEmpty)
    }

    @Test func caseAndDiacriticsAreIgnored() {
        #expect(PaletteSearch.score(query: "ЁЛКА", title: "Елка на новый год") != nil)
        #expect(PaletteSearch.score(query: "cafe", title: "Café menu") != nil)
        #expect(PaletteSearch.score(query: "настр", title: "Настройки проекта") != nil)
    }

    @Test func lettersInOrderMatchFuzzilyButRankLast() {
        let candidates = [
            PaletteSearch.Candidate(id: "fuzzy", title: "Command palette"),
            PaletteSearch.Candidate(id: "exact", title: "cmp tool"),
        ]
        #expect(PaletteSearch.score(query: "cmpl", title: "Command palette") != nil)
        #expect(PaletteSearch.score(query: "x", title: "Command palette") == nil)
        #expect(PaletteSearch.rank(candidates, query: "cmp") == ["exact", "fuzzy"])
    }

    @Test func exactTitleWinsOverLongerTitles() {
        let now = Date()
        let candidates = [
            PaletteSearch.Candidate(id: "long", title: "Archive cleanup", recency: now),
            PaletteSearch.Candidate(id: "exact", title: "Archive", recency: now.addingTimeInterval(-60)),
        ]
        #expect(PaletteSearch.rank(candidates, query: "archive") == ["exact", "long"])
    }
}

@Suite struct SidebarChatOrderTests {
    /// Two projects: Alpha with chats a1…a7 (a3 pinned), Beta with b1 and b2, Hidden with a pinned chat.
    private func fixture() -> (SavedState, alpha: UUID, beta: UUID) {
        var state = SavedState()
        let alpha = state.addProject(path: "/tmp/Alpha")
        let beta = state.addProject(path: "/tmp/Beta")
        let hidden = state.addProject(path: "/tmp/Hidden")
        func chat(_ id: String, _ project: UUID, order: Int, pinned: Bool = false, archived: Bool = false) -> Chat {
            var chat = Chat(id: id, projectID: project, title: "Chat " + id, model: "")
            chat.sidebarOrder = order; chat.pinned = pinned ? true : nil; chat.archived = archived ? true : nil
            return chat
        }
        state.chats = (1...7).map { chat("a\($0)", alpha, order: $0, pinned: $0 == 3) }
            + [chat("b1", beta, order: 1), chat("b2", beta, order: 2), chat("b0", beta, order: 0, archived: true),
               chat("h1", hidden, order: 1, pinned: true)]
        state.hideProject(hidden)
        return (state, alpha, beta)
    }

    @Test func rowsFollowTheSidebarFavoritesFirst() {
        let (state, alpha, beta) = fixture()
        let listing = SidebarListing(expanded: [alpha, beta])
        // One page of five per project; the favorite also stays in its project, the archived chat does not show.
        #expect(state.sidebarChatRows(listing) == ["a3", "a1", "a2", "a3", "a4", "a5", "b1", "b2"])
    }

    @Test func collapsedProjectsAndShowMoreChangeTheRows() {
        let (state, alpha, beta) = fixture()
        #expect(state.sidebarChatRows(SidebarListing(expanded: [beta])) == ["a3", "b1", "b2"])
        #expect(state.sidebarChatRows(SidebarListing(expanded: [alpha], visibleCounts: [alpha: 10]))
                == ["a3", "a1", "a2", "a3", "a4", "a5", "a6", "a7"])
    }

    @Test func searchShowsMatchingChatsInOpenProjects() {
        let (state, alpha, _) = fixture()
        // During a search every matching project is open unless closed by hand, and nothing is paged.
        #expect(state.sidebarChatRows(SidebarListing(search: "Chat b")) == ["b1", "b2"])
        #expect(state.sidebarChatRows(SidebarListing(search: "alpha", collapsedInSearch: [alpha])) == ["a3"])
        #expect(state.sidebarChatRows(SidebarListing(search: "alpha")) == ["a3"] + (1...7).map { "a\($0)" })
    }

    @Test func searchRowLimitSharesRowsAcrossOpenProjectsInOrder() {
        let (state, alpha, beta) = fixture()
        // "Chat" matches every chat: Alpha takes its 7 rows, Beta the remaining 1 of the limit of 8.
        let limited = state.sidebarSections(SidebarListing(search: "Chat", searchLimit: 8))
        #expect(limited.sections.map(\.project.id) == [alpha, beta])
        #expect(limited.sections.map(\.limit) == [7, 1])
        #expect(limited.matching == 9 && limited.hidden == 1)
        #expect(state.sidebarChatRows(SidebarListing(search: "Chat", searchLimit: 8)) == ["a3"] + (1...7).map { "a\($0)" } + ["b1"])
        // "Show all" lifts the limit; a project closed by hand takes no share and keeps one page for opening.
        let all = state.sidebarSections(SidebarListing(search: "Chat"))
        #expect(all.sections.map(\.limit) == [7, 2] && all.hidden == 0)
        let closed = state.sidebarSections(SidebarListing(search: "Chat", collapsedInSearch: [alpha], searchLimit: 1))
        #expect(closed.sections.map(\.limit) == [5, 1] && closed.matching == 2 && closed.hidden == 1)
        // No search: no limit, one page per project, groups equal `orderedChats`.
        let plain = state.sidebarSections(SidebarListing(expanded: [alpha], searchLimit: 1))
        #expect(plain.sections.map(\.limit) == [5, 5] && plain.hidden == 0)
        #expect(plain.sections[0].chats == state.orderedChats(projectID: alpha, archived: false))
        #expect(state.activeChatsByProject()[beta] == state.orderedChats(projectID: beta, archived: false))
    }

    @Test func adjacentChatWrapsAndCountsFavoritesOnce() {
        let (state, alpha, beta) = fixture()
        let listing = SidebarListing(expanded: [alpha, beta])
        #expect(state.adjacentSidebarChat(from: "a3", offset: 1, listing: listing) == "a1")
        #expect(state.adjacentSidebarChat(from: "a2", offset: 1, listing: listing) == "a4")
        #expect(state.adjacentSidebarChat(from: "b2", offset: 1, listing: listing) == "a3")
        #expect(state.adjacentSidebarChat(from: "a3", offset: -1, listing: listing) == "b2")
        #expect(state.adjacentSidebarChat(from: nil, offset: 1, listing: listing) == "a3")
        // Chats behind "Show more" count: a5 is followed by a6, not by b1.
        #expect(state.adjacentSidebarChat(from: "a5", offset: 1, listing: listing) == "a6")
        #expect(state.adjacentSidebarChat(from: "a7", offset: -1, listing: listing) == "a6")
        // Closed projects count too: with everything collapsed the shortcut still moves past the open chat.
        #expect(state.adjacentSidebarChat(from: nil, offset: 1, listing: SidebarListing()) == "a3")
        #expect(state.adjacentSidebarChat(from: "a1", offset: 1, listing: SidebarListing()) == "a2")
        #expect(state.adjacentSidebarChat(from: "b1", offset: -1, listing: SidebarListing()) == "a7")
        // The search still filters.
        #expect(state.adjacentSidebarChat(from: "b1", offset: 1, listing: SidebarListing(search: "Chat b")) == "b2")
        var empty = state; empty.chats = []
        #expect(empty.adjacentSidebarChat(from: nil, offset: 1, listing: listing) == nil)
    }

    @Test func recentChatsAreNewestFirstWithoutArchivedOrHidden() {
        var (state, _, _) = fixture()
        for index in state.chats.indices { state.chats[index].updated = Date(timeIntervalSince1970: 1000 + Double(index)) }
        // Newest first; the archived b0 and the hidden project's h1 are left out; the limit applies.
        #expect(state.recentChats() == ["b2", "b1", "a7", "a6", "a5", "a4", "a3", "a2", "a1"])
        #expect(state.recentChats(limit: 2) == ["b2", "b1"])
    }
}

@MainActor @Suite struct TranscriptFindTests {
    @Test func focusedDocumentAnswersFindBeforeTheChat() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        let document = TranscriptScrollView()
        document.frame = container.bounds
        document.transcript.usesFindBar = true
        container.addSubview(document)
        #expect(window.makeFirstResponder(document.transcript))
        #expect(TranscriptScrollView.findTarget(in: window) === document)
        // A transcript without a find bar never takes Cmd+F.
        document.transcript.usesFindBar = false
        #expect(TranscriptScrollView.findTarget(in: window) !== document)
    }

    @Test func chatTranscriptHasTheFindBar() {
        let host = NSHostingView(rootView: NativeTranscript(items: [], conversationID: "chat", followOutput: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let chat = TranscriptScrollView.chatTranscript
        #expect(chat?.transcript.usesFindBar == true)
        #expect(chat?.transcript.isIncrementalSearchingEnabled == true)
        // Nothing focused inside a transcript: Cmd+F goes to the chat.
        window.makeFirstResponder(nil)
        #expect(TranscriptScrollView.findTarget(in: window) === chat)
    }
}

@Test func chatKeysMatchPhysicalKeysInAnyLayout() {
    // Key codes are layout-independent: the Russian layout types "х" on the [ key, the code stays the same.
    #expect(ChatKey.action(keyCode: 18, modifiers: .command) == .recent(1))
    #expect(ChatKey.action(keyCode: 25, modifiers: [.command, .capsLock]) == .recent(9))
    #expect(ChatKey.action(keyCode: 33, modifiers: [.command, .shift]) == .adjacent(-1))
    #expect(ChatKey.action(keyCode: 30, modifiers: [.command, .shift]) == .adjacent(1))
    // Cmd+[ without Shift stays with the document preview; other modifiers and plain digits are left alone.
    #expect(ChatKey.action(keyCode: 33, modifiers: .command) == nil)
    #expect(ChatKey.action(keyCode: 18, modifiers: [.command, .option]) == nil)
    #expect(ChatKey.action(keyCode: 18, modifiers: []) == nil)
}

@MainActor @Test func paletteRankingRunsOncePerQueryAndState() {
    var state = SavedState()
    var project = Project(path: "/tmp/switchboard"); project.name = "switchboard"
    state.projects = [project]
    state.chats = (0..<30).map { index in
        var chat = Chat(id: "c\(index)", projectID: project.id, title: index % 2 == 0 ? "Archive search \(index)" : "Digest \(index)", model: "m")
        chat.updated = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
        chat.archived = index == 4 ? true : nil
        return chat
    }
    let ranking = PaletteRanking()
    ranking.update(state, query: "arch", chatLimit: 8, projectLimit: 6)
    let candidates = state.chats.filter { !$0.isArchived }
        .map { PaletteSearch.Candidate(id: $0.id, title: $0.title, detail: "switchboard", recency: $0.updated) }
    #expect(ranking.chatIDs == PaletteSearch.rank(candidates, query: "arch", limit: 8))
    #expect(!ranking.chatIDs.contains("c4") && ranking.positions["c7"] == 7)
    #expect(ranking.projectIDs.isEmpty)
    // The same query and state (another chat streaming, an arrow key): no new ranking.
    state.chats[0].model = "other"
    ranking.update(state, query: "arch", chatLimit: 8, projectLimit: 6)
    #expect(ranking.runs == 1)
    ranking.update(state, query: "switch", chatLimit: 8, projectLimit: 6)
    #expect(ranking.runs == 2 && ranking.projectIDs == [project.id])
    state.chats[1].title = "Archive renamed"
    ranking.update(state, query: "switch", chatLimit: 8, projectLimit: 6)
    #expect(ranking.runs == 3)
}
