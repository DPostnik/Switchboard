import AppKit
import ContextCore
import ContextTranscript
import Foundation
import SwiftUI
import Testing

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

    @Test func adjacentChatWrapsAndCountsFavoritesOnce() {
        let (state, alpha, beta) = fixture()
        let listing = SidebarListing(expanded: [alpha, beta])
        #expect(state.adjacentSidebarChat(from: "a3", offset: 1, listing: listing) == "a1")
        #expect(state.adjacentSidebarChat(from: "a2", offset: 1, listing: listing) == "a4")
        #expect(state.adjacentSidebarChat(from: "b2", offset: 1, listing: listing) == "a3")
        #expect(state.adjacentSidebarChat(from: "a3", offset: -1, listing: listing) == "b2")
        #expect(state.adjacentSidebarChat(from: nil, offset: 1, listing: listing) == "a3")
        #expect(state.adjacentSidebarChat(from: "a7", offset: -1, listing: listing) == "b2")
        #expect(state.adjacentSidebarChat(from: nil, offset: 1, listing: SidebarListing()) == "a3")
        var empty = state; empty.chats = []
        #expect(empty.adjacentSidebarChat(from: nil, offset: 1, listing: listing) == nil)
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
