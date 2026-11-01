import Foundation

/// Matching and ranking for the command palette (Cmd+K). Every word of the query must occur in the title or the
/// detail (a chat's project); title matches outrank detail matches, word starts outrank inner substrings, and a
/// title that only contains the letters in order (fuzzy) ranks last. Ties go to the most recent entry.
public enum PaletteSearch {
    public struct Candidate<ID: Hashable & Sendable>: Sendable {
        public var id: ID
        public var title: String
        /// Secondary text that also matches, ranked below the title: the project of a chat, the path of a project.
        public var detail: String
        /// Newer first among equal matches; nil keeps the given order (actions).
        public var recency: Date?
        public init(id: ID, title: String, detail: String = "", recency: Date? = nil) {
            self.id = id; self.title = title; self.detail = detail; self.recency = recency
        }
    }

    /// Case, diacritics (ё = е) and width are ignored.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func words(_ folded: String) -> [Substring] {
        folded.split { !$0.isLetter && !$0.isNumber }
    }

    /// Match score of `query`; nil when a word of the query is missing. An empty query matches everything with 0.
    public static func score(query: String, title: String, detail: String = "") -> Int? {
        let folded = fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = folded.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return 0 }
        let title = fold(title), detail = fold(detail)
        let titleWords = words(title), detailWords = words(detail)
        var total = 0
        for token in tokens {
            if title.hasPrefix(token) { total += 100 }
            else if titleWords.contains(where: { $0.hasPrefix(token) }) { total += 80 }
            else if title.contains(token) { total += 50 }
            else if detailWords.contains(where: { $0.hasPrefix(token) }) { total += 30 }
            else if detail.contains(token) { total += 20 }
            else if token.count >= 2, isSubsequence(token, of: title) { total += 10 }
            else { return nil }
        }
        if title == folded { total += 100 } else if tokens.count > 1, title.hasPrefix(folded) { total += 50 }
        return total
    }

    /// Matching candidates, best first; equal scores newest first, then in the given order. `limit` caps the result.
    public static func rank<ID>(_ candidates: [Candidate<ID>], query: String, limit: Int = .max) -> [ID] {
        let scored = candidates.enumerated().compactMap { offset, candidate in
            score(query: query, title: candidate.title, detail: candidate.detail).map { (candidate, $0, offset) }
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            switch (a.0.recency, b.0.recency) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.2 < b.2
            }
        }.prefix(max(0, limit)).map(\.0.id)
    }

    static func isSubsequence(_ needle: Substring, of haystack: String) -> Bool {
        var remaining = needle[...]
        for character in haystack where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}

/// What the sidebar shows besides the saved state: its search text and which projects are open and how far.
/// The view owns these; the chat shortcuts (Cmd+1…9, previous/next chat) read a copy to follow the visible list.
public struct SidebarListing: Equatable, Sendable {
    public var search = ""
    /// Projects opened while the search is empty.
    public var expanded: Set<UUID> = []
    /// Projects closed during a search; every matching project starts open.
    public var collapsedInSearch: Set<UUID> = []
    /// Chats shown per project after "Show more"; absent shows one page.
    public var visibleCounts: [UUID: Int] = [:]
    public var pageSize = 5
    public init(search: String = "", expanded: Set<UUID> = [], collapsedInSearch: Set<UUID> = [], visibleCounts: [UUID: Int] = [:], pageSize: Int = 5) {
        self.search = search; self.expanded = expanded; self.collapsedInSearch = collapsedInSearch
        self.visibleCounts = visibleCounts; self.pageSize = pageSize
    }

    public func isExpanded(_ project: UUID) -> Bool {
        search.isEmpty ? expanded.contains(project) : !collapsedInSearch.contains(project)
    }
    /// How many of a project's chats are shown before "Show more".
    public func limit(_ project: UUID, chatCount: Int) -> Int {
        search.isEmpty ? (visibleCounts[project] ?? pageSize) : chatCount
    }
}

/// The sidebar's filters for its search field, shared by the list itself and the chat shortcuts.
extension SavedState {
    private func projectMatches(_ project: Project, search: String) -> Bool {
        project.name.localizedCaseInsensitiveContains(search) || project.path.localizedCaseInsensitiveContains(search)
    }
    public func sidebarShowsFavorite(_ chat: Chat, search: String) -> Bool {
        search.isEmpty || chat.title.localizedCaseInsensitiveContains(search)
            || projects.contains { $0.id == chat.projectID && projectMatches($0, search: search) }
    }
    public func sidebarShowsProject(_ project: Project, search: String) -> Bool {
        search.isEmpty || projectMatches(project, search: search)
            || chats.contains { $0.projectID == project.id && !$0.isArchived && $0.title.localizedCaseInsensitiveContains(search) }
    }
    public func sidebarShowsChat(_ chat: Chat, in project: Project, search: String) -> Bool {
        search.isEmpty || projectMatches(project, search: search) || chat.title.localizedCaseInsensitiveContains(search)
    }

    /// Chat rows of the sidebar from top to bottom: favorites, then the shown chats of each open project.
    /// A favorite also appears under its project, as in the sidebar, so the N-th row is the N-th chat on screen.
    public func sidebarChatRows(_ listing: SidebarListing) -> [String] {
        var rows = visiblePinnedChats.filter { sidebarShowsFavorite($0, search: listing.search) }.map(\.id)
        for project in visibleProjects where sidebarShowsProject(project, search: listing.search) && listing.isExpanded(project.id) {
            let shown = orderedChats(projectID: project.id, archived: false).filter { sidebarShowsChat($0, in: project, search: listing.search) }
            rows += shown.prefix(listing.limit(project.id, chatCount: shown.count)).map(\.id)
        }
        return rows
    }

    /// The chat `offset` rows away from `current` in the sidebar, wrapping at the ends; each chat counts once.
    /// Without a current chat on the list, forward starts at the first chat and backward at the last.
    public func adjacentSidebarChat(from current: String?, offset: Int, listing: SidebarListing) -> String? {
        var seen: Set<String> = []
        let rows = sidebarChatRows(listing).filter { seen.insert($0).inserted }
        guard !rows.isEmpty, offset != 0 else { return nil }
        guard let current, let index = rows.firstIndex(of: current) else { return offset > 0 ? rows.first : rows.last }
        let count = rows.count
        return rows[((index + offset) % count + count) % count]
    }
}
